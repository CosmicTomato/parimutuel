// SPDX-License-Identifier: Unlicensed
pragma solidity 0.8.28;

//    _______     __        _______    __     ___      ___  ____  ____  ___________  ____  ____   _______  ___
//   |   __ "\   /""\      /"      \  |" \   |"  \    /"  |("  _||_ " |("     _   ")("  _||_ " | /"     "||"  |
//   (. |__) :) /    \    |:        | ||  |   \   \  //   ||   (  ) : | )__/  \\__/ |   (  ) : |(: ______)||  |
//   |:  ____/ /' /\  \   |_____/   ) |:  |   /\\  \/.    |(:  |  | . )    \\_ /    (:  |  | . ) \/    |  |:  |
//   (|  /    //  __'  \   //      /  |.  |  |: \.        | \\ \__/ //     |.  |     \\ \__/ //  // ___)_  \  |___
//  /|__/ \  /   /  \\  \ |:  __   \  /\  |\ |.  \    /:  | /\\ __ //\     \:  |     /\\ __ //\ (:      "|( \_|:  \
// (_______)(___/    \___)|__|  \___)(__\_|_)|___|\__/|___|(__________)     \__|    (__________) \_______) \_______)

import {Math} from "./libraries/Math.sol";
import {PriceFeed} from "./interfaces/PriceFeed.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract Parimutuel {

    enum Side {
        SHORT,
        LONG
    }

    struct Position {
        // margin maintaining the position
        uint256 margin;
        // size in base / settlement token
        uint256 tokens;
        // potential for share of profits
        uint256 shares;
        // actually realized share of profits
        uint256 activeShares;
        // price at which the position was opened
        uint256 entry;
        // existence of the position
        bool active;

        uint256 lastCumFundingEarnedPerShare;
        uint256 lastCumFundingPaidPerToken;
    }

    struct SideInfo {
        // sum of 'margin' for all positions on the side
        uint256 margin;
        // sum of 'tokens' for all positions on the side
        uint256 tokens;
        // sum of 'shares' for all positions on the side
        uint256 shares;
        // sum of 'activeShares' for all positions on the side
        uint256 activeShares;
        // funding received from the other side. These are earned by all positions on the side proportional to their 'shares',
        // but they are lost if the position is liquidated
        uint256 funds;
        // leverage fees, realized losses, and liquidations paid from the other side.
        // Positions can be closed to claim a share of profits, proportional to their 'activeShares'
        uint256 profits;

        // scaled up by PRECISION
        uint256 cumFundingEarnedPerShare;
        // scaled up by PRECISION
        uint256 cumFundingPaidPerToken;
    }

    error PositionAlreadyActive();
    error PositionNotActive();
    error PositionNotLiquidatable();
    error InvalidLeverage();
    error InvalidSide();
    error NotAuthorized();
    error FundingRateNotDue();
    error LeverageFeeExceedsMargin();

    event PositionOpened(address indexed user, uint256 margin, uint256 leverage, Side side);
    event PositionClosed(address indexed user, uint256 margin, uint256 amountOut, Side side);
    event MarginAdded(address indexed user, uint256 amount, Side side);
    event FundingPaid(uint256 fundingFee, uint256 nextFunding, Side side);

    uint256 internal constant MIN_LEVERAGE = 1 * PRECISION;
    uint256 internal constant MAX_LEVERAGE = 100 * PRECISION;
    uint256 internal constant PRECISION = 10 ** 8;
    uint256 internal constant FUNDING_INTERVAL = 6 hours;
    // number of funding periods over which 100% funding will be charged, if all positions remain on a single side
    uint256 internal constant FUNDING_PERIODS = 4;
    uint256 internal constant FUNDING_DURATION = 10 minutes;
    uint256 internal constant FUNDING_EVENTS_PER_DAY = 24 hours / FUNDING_DURATION;
    // max daily funding rate, scaled up by PRECISION -- i.e. 0.5 * PRECISION = 50% 
    uint256 internal constant MAX_DAILY_FUNDING_RATE = 1 * PRECISION;

    uint256 internal constant BIPS_BASIS = 10000;
    uint256 internal constant PROFIT_FEE_BIPS = 200;
    uint256 internal constant FUNDING_FEE_BIPS = 200;

    address internal feeCollector;
    PriceFeed internal oracle;
    IERC20 internal settlementToken;
    uint256 internal fundingDue;

    mapping(address => mapping(Side => Position)) internal positions;
    mapping(Side => SideInfo) internal sideInfo;

    constructor(address _settlementToken, address _oracle) {
        feeCollector = msg.sender;
        settlementToken = IERC20(_settlementToken);
        oracle = PriceFeed(_oracle);
    }

    function open(address user, uint256 margin, uint256 tokens, Side side) internal {
        require(!_positionExists(user, side), PositionAlreadyActive());

        settlementToken.transferFrom(msg.sender, address(this), margin);

        uint256 _shares = Math.sqrt(tokens + sideInfo[side].tokens) - Math.sqrt(sideInfo[side].tokens);
        uint256 _entry = currentPrice();
        uint256 _leverageFee;

        if (sideInfo[side].tokens != 0) {
            // TODO: compared to this function, 'add liquidity' instead:
            // - charges a 'liquidity fee' calculated as
            // uint256 liquidityFee = (shortProfits * _shares) / totalShares;
            _leverageFee = (tokens * _shares) / sideInfo[side].shares;
            require(_leverageFee < margin, LeverageFeeExceedsMargin());
        }
        uint256 _margin = margin - _leverageFee;
        uint256 leverage = (tokens * PRECISION) / _margin;
        require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, InvalidLeverage());

        sideInfo[side].profits += _leverageFee;
        sideInfo[side].tokens += tokens;
        sideInfo[side].shares += _shares;
        uint256 _activeShares = leverage == MIN_LEVERAGE ? _shares : 0;
        sideInfo[side].activeShares += _activeShares;
        sideInfo[side].margin += _margin;
        // shortUsers.push(user);

        positions[user][side] = Position({
            margin: _margin,
            tokens: tokens,
            shares: _shares,
            activeShares: _activeShares,
            entry: _entry,
            active: true,
            lastCumFundingEarnedPerShare: sideInfo[side].cumFundingEarnedPerShare,
            lastCumFundingPaidPerToken: sideInfo[side].cumFundingPaidPerToken
        });

        emit PositionOpened(user, margin, leverage, side);
    }

    function liquidate(address user, Side side) external {
        require(_positionExists(user, side), PositionNotActive());

        Position storage pos = positions[user][side];
        uint256 price = currentPrice();
        uint256 liquidation = _liqCalc(pos, side);

        if (side == Side.SHORT) {
            // user liquidated
            require(price >= liquidation, PositionNotLiquidatable());
        } else if (side == Side.LONG) {
            // user liquidated
            require(price <= liquidation, PositionNotLiquidatable());
        } else {
            revert InvalidSide();
        }
        _close(user, side);
    }

    function close(Side side) external {
        _close(msg.sender, side);
    }

    function _close(address user, Side side) internal {
        require(_positionExists(user, side), PositionNotActive());

        Position storage pos = positions[user][side];
        uint256 price = currentPrice();
        uint256 liquidation = _liqCalc(pos, side);

        _positionUpdate(pos, side);

        uint256 shareProfits = (sideInfo[side].profits * pos.activeShares) / sideInfo[side].activeShares;
        uint256 netShareProfit = (shareProfits * (BIPS_BASIS - PROFIT_FEE_BIPS)) / BIPS_BASIS;
        uint256 profitFee = shareProfits - netShareProfit;

        uint256 transferToUser;
        if (side == Side.SHORT) {
            // user liquidated
            if (price >= liquidation) {
                transferToUser = 0;
                sideInfo[Side.LONG].profits += pos.margin;
            // user has losses
            } else if (price >= pos.entry) {
                uint256 marginValue = (pos.margin * (liquidation - price)) / (liquidation - pos.entry);
                uint256 loss = pos.margin - marginValue;
                sideInfo[_getOtherSide(side)].profits += loss;
                transferToUser = marginValue;
            // user in profit
            } else if (price < pos.entry) {
                transferToUser = pos.margin + netShareProfit;
                sideInfo[side].profits -= shareProfits;
            }
        } else if (side == Side.LONG) {
            // user liquidated
            if (price <= liquidation) {
                transferToUser = 0;
                sideInfo[Side.SHORT].profits += pos.margin;
            // user has losses
            } else if (price <= pos.entry) {
                uint256 marginValue = (pos.margin * (price - liquidation)) / (pos.entry - liquidation);
                uint256 loss = pos.margin - marginValue;
                sideInfo[_getOtherSide(side)].profits += loss;
                transferToUser = marginValue;
            // user in profit
            } else if (price > pos.entry) {
                transferToUser = pos.margin + netShareProfit;
                sideInfo[side].profits -= shareProfits;
            }
        } else {
            revert InvalidSide();
        }

        sideInfo[side].tokens -= pos.tokens;
        sideInfo[side].shares -= pos.shares;
        sideInfo[side].activeShares -= pos.activeShares;
        sideInfo[side].margin -= pos.margin;
        emit PositionClosed(user, pos.margin, transferToUser, side);
        delete positions[user][side];

        settlementToken.transfer(user, transferToUser);
        settlementToken.transfer(feeCollector, profitFee);
    }

    function addMargin(address user, uint256 amount, Side side) external {
        require(_positionExists(user, side), PositionNotActive());

        settlementToken.transferFrom(msg.sender, address(this), amount);
        Position storage pos = positions[user][side];

        pos.margin += amount;
        uint256 leverage = (pos.tokens * PRECISION) / pos.margin;
        require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, InvalidLeverage());

        _positionUpdate(pos, side);

        emit MarginAdded(user, amount, side);
    }

    function triggerFunding() public {
        require(block.timestamp >= fundingDue, FundingRateNotDue());
        fundingDue += FUNDING_INTERVAL;

        uint256 shortTokens = sideInfo[Side.SHORT].tokens;
        uint256 longTokens = sideInfo[Side.LONG].tokens;
        Side side = (shortTokens > longTokens) ? Side.SHORT : Side.LONG;
        uint256 otherSideShares = sideInfo[_getOtherSide(side)].shares;

        // avoid paying when no position is on the other side (avoids divide-by-zero errors)
        if (otherSideShares != 0) {
            uint256 sideTokens = sideInfo[side].tokens;
            uint256 otherSideTokens = sideInfo[_getOtherSide(side)].tokens;

            uint256 totalTokens = sideTokens + otherSideTokens;
            uint256 difference = sideTokens - otherSideTokens;
            uint256 funding = (sideInfo[side].margin * difference * MAX_DAILY_FUNDING_RATE)
                / (totalTokens * FUNDING_EVENTS_PER_DAY * PRECISION);

            uint256 netFunding = (funding * (BIPS_BASIS - FUNDING_FEE_BIPS)) / BIPS_BASIS;
            uint256 fundingFee = funding - netFunding;

            sideInfo[side].margin -= funding;
            sideInfo[_getOtherSide(side)].margin += netFunding;
            sideInfo[side].cumFundingPaidPerToken += (funding * PRECISION) / sideInfo[side].tokens;
            sideInfo[_getOtherSide(side)].cumFundingEarnedPerShare += (netFunding * PRECISION) / otherSideShares;
            emit FundingPaid(funding, fundingDue + FUNDING_INTERVAL, side);

            settlementToken.transfer(feeCollector, fundingFee);
        }
    }

    function _positionUpdate(Position storage pos, Side side) internal {
        uint256 fundingEarned = (sideInfo[side].cumFundingEarnedPerShare - pos.lastCumFundingEarnedPerShare) * pos.shares / PRECISION;
        uint256 fundingPaid = (sideInfo[side].cumFundingPaidPerToken - pos.lastCumFundingPaidPerToken) * pos.tokens / PRECISION;
        pos.lastCumFundingEarnedPerShare = sideInfo[side].cumFundingEarnedPerShare;
        pos.lastCumFundingPaidPerToken = sideInfo[side].cumFundingPaidPerToken;

        // position is underwater
        if (fundingPaid > fundingEarned + pos.margin) {
            // TODO: should probably just liquidate?
            pos.margin = 0;
        } else {
            pos.margin = (pos.margin + fundingEarned) - fundingPaid;
        }

        uint256 startingActiveShares = pos.activeShares;
        uint256 price = currentPrice();
        uint256 _activeShares;

        if (pos.margin == 0) {
            _activeShares = 0;
        } else {
            if (side == Side.SHORT) {
                uint256 profit = pos.entry - ((pos.entry * pos.margin) / pos.tokens);
                if (price <= profit) {
                    _activeShares = pos.shares;
                } else if (price >= pos.entry) {
                    _activeShares = 0;
                } else {
                    uint256 numerator = price - profit;
                    uint256 denominator = pos.entry - profit;
                    _activeShares = (pos.shares * numerator) / denominator;
                }
            } else if (side == Side.LONG) {
                uint256 profit = pos.entry + ((pos.entry * pos.margin) / pos.tokens);
                if (price >= profit) {
                    _activeShares = pos.shares;
                } else if (price <= pos.entry) {
                    _activeShares = 0;
                } else {
                    uint256 numerator = price - pos.entry;
                    uint256 denominator = profit - pos.entry;
                    _activeShares = (pos.shares * numerator) / denominator;
                }
            } else {
                revert InvalidSide();
            }
        }

        pos.activeShares = _activeShares;
        sideInfo[side].activeShares = sideInfo[side].activeShares + _activeShares - startingActiveShares;
    }

    function _getOtherSide(Side side) internal pure returns (Side) {
        if (side == Side.SHORT) {
            return Side.LONG;
        } else if (side == Side.LONG) {
            return Side.SHORT;
        } else {
            revert InvalidSide();
        }
    }

    function _positionExists(address user, Side side) internal view returns (bool) {
        return positions[user][side].active;
    }

    function _liqCalc(
        Position storage pos,
        Side side
    ) internal view returns (uint256 liquidation) {

        if (side == Side.SHORT) {
            return pos.entry + ((pos.entry * pos.margin) / pos.tokens);
        } else if (side == Side.LONG) {
            return pos.entry - ((pos.entry * pos.margin) / pos.tokens);
        } else {
            revert InvalidSide();
        }
    }

    function currentPrice() public view returns (uint256) {
        (, int256 _price, , , ) = oracle.latestRoundData();
        if (_price < 0) _price = 0;
        return uint256(_price);
    }
}