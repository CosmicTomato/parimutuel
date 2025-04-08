// SPDX-License-Identifier: Unlicensed
pragma solidity 0.8.28;

//    _______     __        _______    __     ___      ___  ____  ____  ___________  ____  ____   _______  ___
//   |   __ "\   /""\      /"      \  |" \   |"  \    /"  |("  _||_ " |("     _   ")("  _||_ " | /"     "||"  |
//   (. |__) :) /    \    |:        | ||  |   \   \  //   ||   (  ) : | )__/  \\__/ |   (  ) : |(: ______)||  |
//   |:  ____/ /' /\  \   |_____/   ) |:  |   /\\  \/.    |(:  |  | . )    \\_ /    (:  |  | . ) \/    |  |:  |
//   (|  /    //  __'  \   //      /  |.  |  |: \.        | \\ \__/ //     |.  |     \\ \__/ //  // ___)_  \  |___
//  /|__/ \  /   /  \\  \ |:  __   \  /\  |\ |.  \    /:  | /\\ __ //\     \:  |     /\\ __ //\ (:      "|( \_|:  \
// (_______)(___/    \___)|__|  \___)(__\_|_)|___|\__/|___|(__________)     \__|    (__________) \_______) \_______)

import {Array} from "./libraries/Array.sol";
import {Math} from "./libraries/Math.sol";
import {PriceFeed} from "./interfaces/PriceFeed.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract Parimutuel {

    enum Side {
        SHORT,
        LONG
    }

    struct Position {
        address owner;
        uint256 margin;
        uint256 leverage;
        uint256 tokens;
        uint256 shares;
        uint256 activeShares;
        uint256 value;
        uint256 entry;
        uint256 liquidation;
        uint256 profit;
        uint256 funding;
        bool active;
    }

    struct SideInfo {
        uint256 tokens;
        uint256 shares;
        uint256 activeShares;
        uint256 funds;
        uint256 profits;
    }

    error PositionAlreadyActive();
    error PositionNotActive();
    error InvalidLeverage();
    error InvalidSide();
    error NotAuthorized();
    error FundingRateNotDue();
    error LeverageFeeExceedsMargin();

    event PositionOpened(address indexed user, uint256 margin, uint256 leverage, Side side);
    event Liquidated();
    event ClosedAtLoss();
    event ClosedAtProfit();
    event MarginAdded();
    event FundingPaid();

    uint256 internal constant MIN_LEVERAGE = 1 * PRECISION;
    uint256 internal constant MAX_LEVERAGE = 100 * PRECISION;
    uint256 internal constant PRECISION = 10 ** 8;
    uint256 internal constant FUNDING_INTERVAL = 21600;
    uint256 internal constant FUNDING_PERIODS = 4;

    address internal admin;
    address internal feeCollector;
    PriceFeed internal oracle;
    IERC20 internal usd;

    mapping(address => mapping(Side => Position)) internal positions;
    mapping(Side => SideInfo) internal sideInfo;

    constructor(address _usd, address _oracle) {
        admin = msg.sender;
        feeCollector = msg.sender;
        usd = IERC20(_usd);
        oracle = PriceFeed(_oracle);
    }

    // function shortAddLiquidity(address user, uint256 tokens) external {
    //     usd.transferFrom(msg.sender, address(this), tokens);

    //     uint256 _shares = shares(tokens, shortTokens);
    //     uint256 totalShares = shortShares + _shares;
    //     uint256 depositAfterFee = tokens - liquidityFee;

    //     shortProfits += liquidityFee;
    //     shortTokens += tokens;
    //     shortShares += _shares;
    //     shortActiveShares += _shares;

    //     shortLPs[user] = Liquidity({
    //         owner: user,
    //         tokens: depositAfterFee,
    //         shares: _shares,
    //         active: true
    //     });
    // }

    function open(address user, uint256 margin, uint256 leverage, Side side) internal {
        require(!_positionExists(user, side), PositionAlreadyActive());
        require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, InvalidLeverage());

        usd.transferFrom(msg.sender, address(this), margin);

        uint256 notionalSize = (margin * leverage) / PRECISION;
        uint256 _shares = shares(notionalSize, side);
        uint256 _entry = currentPrice();
        uint256 _leverageFee;
        uint256 _margin;

        if (sideInfo[side].tokens == 0) {
            _margin = margin;
        } else {
            _leverageFee = leverageFee(notionalSize, _shares, side);
            if (_leverageFee >= margin) revert LeverageFeeExceedsMargin();
            _margin = margin - _leverageFee;
        }

        // TODO: compared to this function, 'add liquidity' instead:
        // - charges a 'liquidity fee' calculated as
        // uint256 liquidityFee = (_shares * shortProfits) / totalShares;
        // rather than the 'leverage fee' charged here
        // - because the liquidation is 0 and profit is at entry, the side's active shares are immediately increased
        // - the side's tokens are updated based on the deposit *after* fee, whereas here they are updated based on notionalSize (DISCREPANCY!)

        uint256 _leverage = leverageCalc(notionalSize, _margin);

        sideInfo[side].profits += _leverageFee;
        sideInfo[side].tokens += notionalSize;
        sideInfo[side].shares += _shares;
        // shortUsers.push(user);

        positions[user][side] = Position({
            owner: user,
            margin: _margin,
            leverage: _leverage,
            tokens: notionalSize,
            shares: _shares,
            activeShares: 0,
            value: _margin,
            entry: _entry,
            liquidation: _liqCalc(_entry, _leverage, side),
            profit: _profitCalc(_entry, _leverage, side),
            funding: block.timestamp + FUNDING_INTERVAL,
            active: true
        });

        emit PositionOpened(user, margin, leverage, side);
    }

    function close(address user, Side side) public {
        require(_positionExists(user, side), PositionNotActive());
        // TODO: fix this access control
        onlyOwnerOrAdmin(user);

        Position storage pos = positions[user][side];
        uint256 price = currentPrice();

        if (side == Side.SHORT) {
            if (price >= pos.liquidation) {
                _liquidate(pos, side);
            } else if (price >= pos.entry) {
                _closeLoss(user, pos, side );
            } else if (price < pos.entry) {
                _closeProfit(user, pos, side);
            }
        } else if (side == Side.LONG) {
            if (price <= pos.liquidation) {
                _liquidate(pos, side);
            } else if (price <= pos.entry) {
                _closeLoss(user, pos, side );
            } else if (price > pos.entry) {
                _closeProfit(user, pos, side);
            }
        } else {
            revert InvalidSide();
        }
        delete positions[user][side];
    }

    function _liquidate(Position storage pos, Side side) internal {
        sideInfo[side].tokens -= pos.tokens;
        sideInfo[side].shares -= pos.shares;
        sideInfo[side].activeShares -= pos.activeShares;
        sideInfo[_getOtherSide(side)].profits += pos.margin;

        // TODO: fields in event
        emit Liquidated();
        // shortUsers.remove(user);
    }

    function _closeLoss(address user, Position storage pos, Side side) internal {
        uint256 marginValue = _marginValue(pos, side);
        uint256 fundValue = _fundValue(pos, side);

        // TODO: combine this with other close logic?
        uint256 loss = pos.margin - marginValue;

        sideInfo[side].tokens -= pos.tokens;
        sideInfo[side].shares -= pos.shares;
        sideInfo[side].activeShares -= pos.activeShares;
        sideInfo[side].funds -= fundValue;
        sideInfo[_getOtherSide(side)].profits += loss;

        usd.transfer(user, marginValue + fundValue);

        // TODO: fields in event
        emit ClosedAtLoss();
        // shortUsers.remove(user);
    }

    // TODO: note that compared to 'closeProfit', this function ('shortRemoveLiquidity') does
    // - `profit` calculated based off of the total number of shares, rather than 'active' shares
    // - no calculation of 'fundProfits' and no change to side funds at all
    // - original tokens (margin) not returned to user -- this is just a bug

    // function shortRemoveLiquidity(address user) external {
    //     Liquidity storage liquidity = shortLPs[user];
    //     uint256 profit = (liquidity.shares * shortProfits) / shortShares;
    //     uint256 netProfit = (profit * (10000 - 200)) / 10000;
    //     uint256 fee = profit - netProfit;

    //     shortProfits -= profit;
    //     shortTokens -= liquidity.tokens;
    //     shortShares -= liquidity.shares;
    //     shortActiveShares -= liquidity.shares;

    //     usd.transfer(user, netProfit);
    //     usd.transfer(feeCollector, fee);

    //     delete shortLPs[user];
    // }

    function _closeProfit(address user, Position storage pos, Side side) internal {
        _activeShareUpdate(pos, side);

        // TODO: these *just* got calculated above
        uint256 shareProfits = _shareValue(pos, side);
        uint256 fundProfits = _fundValue(pos, side);

        uint256 netShareProfit = (shareProfits * (10000 - 200)) / 10000;
        uint256 netFundProfit = (fundProfits * (10000 - 200)) / 10000;
        uint256 shareFee = shareProfits - netShareProfit;
        uint256 fundFee = fundProfits - netFundProfit;

        sideInfo[side].tokens -= pos.tokens;
        sideInfo[side].shares -= pos.shares;
        sideInfo[side].activeShares -= pos.activeShares;
        sideInfo[side].funds -= fundProfits;
        sideInfo[side].profits -= shareProfits;

        usd.transfer(user, pos.margin + netShareProfit + netFundProfit);
        usd.transfer(feeCollector, shareFee + fundFee);

        // TODO: fields in event
        emit ClosedAtProfit();
        // shortUsers.remove(user);
    }

    // TODO: compare opening a position and immediately adding margin to opening a position with larger initial margin
    function addMargin(uint256 amount, Side side) external {
        require(_positionExists(msg.sender, side), PositionNotActive());

        usd.transferFrom(msg.sender, address(this), amount);
        Position storage pos = positions[msg.sender][side];
        _activeShareUpdate(pos, side);

        pos.margin += amount;
        pos.leverage = leverageCalc(pos.tokens, pos.margin);
        pos.liquidation = _liqCalc(pos.entry, pos.leverage, side);
        pos.profit = _profitCalc(pos.entry, pos.leverage, side);

        // TODO: add event fields
        emit MarginAdded();
    }

    function triggerFunding(address user, Side side) public {
        require(_positionExists(user, side), PositionNotActive());

        Position storage pos = positions[user][side];
        require(block.timestamp >= pos.funding, FundingRateNotDue());

        uint256 fundingFee;
        uint256 sideTokens = sideInfo[side].tokens;
        uint256 otherSideTokens = sideInfo[_getOtherSide(side)].tokens;
        if (sideTokens <= otherSideTokens) {
            fundingFee = 0;
        } else {
            uint256 totalTokens = sideTokens + otherSideTokens;
            uint256 difference = sideTokens - otherSideTokens;
            // TODO: this is simplified from POC -- it backs out margin independently via extra steps
            fundingFee = (pos.margin * difference) / (FUNDING_PERIODS * totalTokens);
        }

        if (fundingFee >= pos.margin) {
            return close(user, side);
        } else {
            pos.margin -= fundingFee;
            sideInfo[_getOtherSide(side)].funds += fundingFee;
            pos.funding += FUNDING_INTERVAL;
            _activeShareUpdate(pos, side);
            pos.leverage = leverageCalc(pos.tokens, pos.margin);
            pos.liquidation = _liqCalc(pos.entry, pos.leverage, side);
            pos.profit = _profitCalc(pos.entry, pos.leverage, side);

            // TODO: add event fields
            emit FundingPaid();
        }
    }

    function _activeShareUpdate(Position storage pos, Side side) internal {
        uint256 startingActiveShares = pos.activeShares;
        uint256 price = currentPrice();
        uint256 _activeShares;

        if (side == Side.SHORT) {
            if (price <= pos.profit) {
                _activeShares = pos.shares;
            } else if (price >= pos.entry) {
                _activeShares = 0;
            } else {
                uint256 numerator = price - pos.profit;
                uint256 denominator = pos.entry - pos.profit;
                _activeShares = (pos.shares * numerator) / denominator;
            }
        } else if (side == Side.LONG) {
            if (price >= pos.profit) {
                _activeShares = pos.shares;
            } else if (price <= pos.entry) {
                _activeShares = 0;
            } else {
                uint256 numerator = price - pos.entry;
                uint256 denominator = pos.profit - pos.entry;
                _activeShares = (pos.shares * numerator) / denominator;
            }
        } else {
            revert InvalidSide();
        }

        pos.activeShares = _activeShares;
        sideInfo[side].activeShares -= startingActiveShares;
        sideInfo[side].activeShares += pos.activeShares;
        pos.value =
            _marginValue(pos, side) +
            _shareValue(pos, side) +
            _fundValue(pos, side);
    }

    function _shareValue(
        Position storage pos,
        Side side
    ) internal view returns (uint256) {
        return (sideInfo[side].profits * pos.activeShares) / sideInfo[side].activeShares;
    }

    function _fundValue(
        Position storage pos,
        Side side
    ) internal view returns (uint256) {
        return (pos.shares * sideInfo[side].funds) / sideInfo[side].shares;
    }

    function _marginValue(
        Position storage pos,
        Side side
    ) internal view returns (uint256) {
        uint256 price = currentPrice();

        if (side == Side.SHORT) {
            // TODO: new code -- prevents reverts for underflow
            if (price > pos.liquidation) {
                return 0;
            // TODO: should be impossible for entry to be above liquidation
            } else {
                return
                    (pos.margin * (pos.liquidation - price)) /
                    (pos.liquidation - pos.entry);
            }
        } else if (side == Side.LONG) {
            // TODO: new code -- prevents reverts for underflow
            if (pos.liquidation > price) {
                return 0;
            // TODO: should be impossible for entry to be below liquidation
            } else {
                return
                    (pos.margin * (price - pos.liquidation)) /
                    (pos.entry - pos.liquidation);
            }
        } else {
            revert InvalidSide();
        }
    }

    // TODO: unused fnc
    function _value(
        Position storage pos,
        Side side
    ) internal view returns (uint256) {
        return
            _marginValue(pos, side) +
            _shareValue(pos, side) +
            _fundValue(pos, side);
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

    function shares(
        uint256 tokens,
        Side side
    ) public view returns (uint256 _shares) {
        uint256 marketTokens = sideInfo[side].tokens;
        return Math.sqrt(tokens + marketTokens) - Math.sqrt(marketTokens);
    }

    function leverageFee(
        uint256 positionTokens,
        uint256 positionShares,
        Side side
    ) public view returns (uint256 _leverageFee) {
        return (positionTokens * positionShares) / sideInfo[side].shares;
    }

    function _liqCalc(
        uint256 entry,
        uint256 leverage,
        Side side
    ) internal pure returns (uint256 liquidation) {
        if (side == Side.SHORT) {
            return entry + ((entry * PRECISION) / leverage);
        } else if (side == Side.LONG) {
            return entry - ((entry * PRECISION) / leverage);
        } else {
            revert InvalidSide();
        }
    }

    function _profitCalc(
        uint256 entry,
        uint256 leverage,
        Side side
    ) internal pure returns (uint256 profit) {
        if (side == Side.SHORT) {
            return entry - ((entry * PRECISION) / leverage);
        } else if (side == Side.LONG) {
            return entry + ((entry * PRECISION) / leverage);
        } else {
            revert InvalidSide();
        }
    }

    function currentPrice() public view returns (uint256) {
        (, int256 _price, , , ) = oracle.latestRoundData();
        if (_price < 0) _price = 0;
        return uint256(_price);
    }

    function leverageCalc(
        uint256 tokens,
        uint256 margin
    ) internal pure returns (uint256 leverage) {
        return (tokens * PRECISION) / margin;
    }

    /// ============================================================================================
    /// Private Functions
    /// ============================================================================================

    function onlyAdmin() private view {
        require(msg.sender == admin, NotAuthorized());
    }

    function onlyOwnerOrAdmin(address owner) private view {
        require(
            msg.sender == owner ||
                msg.sender == admin ||
                msg.sender == address(this),
            NotAuthorized()
        );
    }




    using Array for address[];

    // address[] private shortUsers;
    // address[] private longUsers;

    // function shortPositions() external view returns (Position[] memory) {
    //     Position[] memory positions = new Position[](shortUsers.length);
    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         positions[i] = shorts[shortUsers[i]];
    //     }
    //     return positions;
    // }

    // function longPositions() external view returns (Position[] memory) {
    //     Position[] memory positions = new Position[](longUsers.length);
    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         positions[i] = longs[longUsers[i]];
    //     }
    //     return positions;
    // }

    // function globalStats()
    //     external
    //     view
    //     returns (uint256, uint256, uint256, uint256)
    // {
    //     return (shortTokens, shortShares, longTokens, longShares);
    // }

    // /// ============================================================================================
    // /// Funding Rate Engine
    // /// ============================================================================================

    // function shortFundings() external view returns (address[] memory) {
    //     uint256 count = 0;

    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         if (shorts[shortUsers[i]].funding <= block.timestamp) {
    //             count++;
    //         }
    //     }

    //     address[] memory positions = new address[](count);
    //     uint256 index = 0;

    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         if (shorts[shortUsers[i]].funding <= block.timestamp) {
    //             positions[index] = shortUsers[i];
    //             index++;
    //         }
    //     }
    //     return positions;
    // }

    // function longFundings() external view returns (address[] memory) {
    //     uint256 count = 0;

    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         if (longs[longUsers[i]].funding <= block.timestamp) {
    //             count++;
    //         }
    //     }

    //     address[] memory positions = new address[](count);
    //     uint256 index = 0;

    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         if (longs[longUsers[i]].funding <= block.timestamp) {
    //             positions[index] = longUsers[i];
    //             index++;
    //         }
    //     }
    //     return positions;
    // }

    // function fundingShortList(address[] calldata list) external {
    //     for (uint i = 0; i < list.length; i++) {
    //         this.shortFundRate(list[i]);
    //     }
    // }

    // function fundingLongList(address[] calldata list) external {
    //     for (uint i = 0; i < list.length; i++) {
    //         this.longFundRate(list[i]);
    //     }
    // }

    // /// ============================================================================================
    // /// Liquidation Engine
    // /// ============================================================================================

    // function shortLiquidations() external view returns (address[] memory) {
    //     uint256 price = currentPrice();
    //     uint256 count = 0;

    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         if (price >= shorts[shortUsers[i]].liquidation) {
    //             count++;
    //         }
    //     }

    //     address[] memory positions = new address[](count);
    //     uint256 index = 0;

    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         if (price >= shorts[shortUsers[i]].liquidation) {
    //             positions[index] = shortUsers[i];
    //             index++;
    //         }
    //     }
    //     return positions;
    // }

    // function longLiquidations() external view returns (address[] memory) {
    //     uint256 price = currentPrice();
    //     uint256 count = 0;

    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         if (price <= longs[longUsers[i]].liquidation) {
    //             count++;
    //         }
    //     }

    //     address[] memory positions = new address[](count);
    //     uint256 index = 0;

    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         if (price <= longs[longUsers[i]].liquidation) {
    //             positions[index] = longUsers[i];
    //             index++;
    //         }
    //     }
    //     return positions;
    // }

    // /// ============================================================================================
    // /// Testnet Simulation
    // /// ============================================================================================

    // function simulateShorts(
    //     address[] calldata users,
    //     uint256[] calldata margins,
    //     uint256[] calldata leverages
    // ) external {
    //     onlyAdmin();
    //     for (uint256 i = 0; i < users.length; i++) {
    //         try
    //             this._simulateShortSingle(
    //                 msg.sender,
    //                 users[i],
    //                 margins[i],
    //                 leverages[i]
    //             )
    //         {} catch {
    //             continue;
    //         }
    //     }
    // }

    // function _simulateShortSingle(
    //     address sender,
    //     address user,
    //     uint256 margin,
    //     uint256 leverage
    // ) external {
    //     usd.transferFrom(sender, address(this), margin);
    //     _shortOpen(user, margin, leverage);
    // }

    // function simulateLongs(
    //     address[] calldata users,
    //     uint256[] calldata margins,
    //     uint256[] calldata leverages
    // ) external {
    //     onlyAdmin();
    //     for (uint256 i = 0; i < users.length; i++) {
    //         try
    //             this._simulateLongSingle(
    //                 msg.sender,
    //                 users[i],
    //                 margins[i],
    //                 leverages[i]
    //             )
    //         {} catch {
    //             continue;
    //         }
    //     }
    // }

    // function _simulateLongSingle(
    //     address sender,
    //     address user,
    //     uint256 margin,
    //     uint256 leverage
    // ) external {
    //     usd.transferFrom(sender, address(this), margin);
    //     _longOpen(user, margin, leverage);
    // }

    // function closeShortList(address[] calldata list) external {
    //     onlyAdmin();
    //     for (uint256 i = 0; i < list.length; i++) {
    //         this.shortClose(list[i]);
    //     }
    // }

    // function closeLongList(address[] calldata list) external {
    //     onlyAdmin();
    //     for (uint256 i = 0; i < list.length; i++) {
    //         this.longClose(list[i]);
    //     }
    // }
}
ction leverageFee(
        uint256 positionTokens,
        uint256 positionShares,
        Side side
    ) public view returns (uint256 _leverageFee) {
        return (positionTokens * positionShares) / sideInfo[side].shares;
    }

    function _liqCalc(
        uint256 entry,
        uint256 leverage,
        Side side
    ) internal pure returns (uint256 liquidation) {
        if (side == Side.SHORT) {
            return entry + ((entry * PRECISION) / leverage);
        } else if (side == Side.LONG) {
            return entry - ((entry * PRECISION) / leverage);
        } else {
            revert InvalidSide();
        }
    }

    function _profitCalc(
        uint256 entry,
        uint256 leverage,
        Side side
    ) internal pure returns (uint256 profit) {
        if (side == Side.SHORT) {
            return entry - ((entry * PRECISION) / leverage);
        } else if (side == Side.LONG) {
            return entry + ((entry * PRECISION) / leverage);
        } else {
            revert InvalidSide();
        }
    }

    function currentPrice() public view returns (uint256) {
        (, int256 _price, , , ) = oracle.latestRoundData();
        if (_price < 0) _price = 0;
        return uint256(_price);
    }

    function leverageCalc(
        uint256 tokens,
        uint256 margin
    ) internal pure returns (uint256 leverage) {
        return (tokens * PRECISION) / margin;
    }

    /// ============================================================================================
    /// Private Functions
    /// ============================================================================================

    function onlyAdmin() private view {
        require(msg.sender == admin, NotAuthorized());
    }

    function onlyOwnerOrAdmin(address owner) private view {
        require(
            msg.sender == owner ||
                msg.sender == admin ||
                msg.sender == address(this),
            NotAuthorized()
        );
    }




    using Array for address[];

    // address[] private shortUsers;
    // address[] private longUsers;

    // function shortPositions() external view returns (Position[] memory) {
    //     Position[] memory positions = new Position[](shortUsers.length);
    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         positions[i] = shorts[shortUsers[i]];
    //     }
    //     return positions;
    // }

    // function longPositions() external view returns (Position[] memory) {
    //     Position[] memory positions = new Position[](longUsers.length);
    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         positions[i] = longs[longUsers[i]];
    //     }
    //     return positions;
    // }

    // function globalStats()
    //     external
    //     view
    //     returns (uint256, uint256, uint256, uint256)
    // {
    //     return (shortTokens, shortShares, longTokens, longShares);
    // }

    // /// ============================================================================================
    // /// Funding Rate Engine
    // /// ============================================================================================

    // function shortFundings() external view returns (address[] memory) {
    //     uint256 count = 0;

    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         if (shorts[shortUsers[i]].funding <= block.timestamp) {
    //             count++;
    //         }
    //     }

    //     address[] memory positions = new address[](count);
    //     uint256 index = 0;

    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         if (shorts[shortUsers[i]].funding <= block.timestamp) {
    //             positions[index] = shortUsers[i];
    //             index++;
    //         }
    //     }
    //     return positions;
    // }

    // function longFundings() external view returns (address[] memory) {
    //     uint256 count = 0;

    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         if (longs[longUsers[i]].funding <= block.timestamp) {
    //             count++;
    //         }
    //     }

    //     address[] memory positions = new address[](count);
    //     uint256 index = 0;

    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         if (longs[longUsers[i]].funding <= block.timestamp) {
    //             positions[index] = longUsers[i];
    //             index++;
    //         }
    //     }
    //     return positions;
    // }

    // function fundingShortList(address[] calldata list) external {
    //     for (uint i = 0; i < list.length; i++) {
    //         this.shortFundRate(list[i]);
    //     }
    // }

    // function fundingLongList(address[] calldata list) external {
    //     for (uint i = 0; i < list.length; i++) {
    //         this.longFundRate(list[i]);
    //     }
    // }

    // /// ============================================================================================
    // /// Liquidation Engine
    // /// ============================================================================================

    // function shortLiquidations() external view returns (address[] memory) {
    //     uint256 price = currentPrice();
    //     uint256 count = 0;

    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         if (price >= shorts[shortUsers[i]].liquidation) {
    //             count++;
    //         }
    //     }

    //     address[] memory positions = new address[](count);
    //     uint256 index = 0;

    //     for (uint256 i = 0; i < shortUsers.length; i++) {
    //         if (price >= shorts[shortUsers[i]].liquidation) {
    //             positions[index] = shortUsers[i];
    //             index++;
    //         }
    //     }
    //     return positions;
    // }

    // function longLiquidations() external view returns (address[] memory) {
    //     uint256 price = currentPrice();
    //     uint256 count = 0;

    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         if (price <= longs[longUsers[i]].liquidation) {
    //             count++;
    //         }
    //     }

    //     address[] memory positions = new address[](count);
    //     uint256 index = 0;

    //     for (uint256 i = 0; i < longUsers.length; i++) {
    //         if (price <= longs[longUsers[i]].liquidation) {
    //             positions[index] = longUsers[i];
    //             index++;
    //         }
    //     }
    //     return positions;
    // }

    // /// ============================================================================================
    // /// Testnet Simulation
    // /// ============================================================================================

    // function simulateShorts(
    //     address[] calldata users,
    //     uint256[] calldata margins,
    //     uint256[] calldata leverages
    // ) external {
    //     onlyAdmin();
    //     for (uint256 i = 0; i < users.length; i++) {
    //         try
    //             this._simulateShortSingle(
    //                 msg.sender,
    //                 users[i],
    //                 margins[i],
    //                 leverages[i]
    //             )
    //         {} catch {
    //             continue;
    //         }
    //     }
    // }

    // function _simulateShortSingle(
    //     address sender,
    //     address user,
    //     uint256 margin,
    //     uint256 leverage
    // ) external {
    //     usd.transferFrom(sender, address(this), margin);
    //     _shortOpen(user, margin, leverage);
    // }

    // function simulateLongs(
    //     address[] calldata users,
    //     uint256[] calldata margins,
    //     uint256[] calldata leverages
    // ) external {
    //     onlyAdmin();
    //     for (uint256 i = 0; i < users.length; i++) {
    //         try
    //             this._simulateLongSingle(
    //                 msg.sender,
    //                 users[i],
    //                 margins[i],
    //                 leverages[i]
    //             )
    //         {} catch {
    //             continue;
    //         }
    //     }
    // }

    // function _simulateLongSingle(
    //     address sender,
    //     address user,
    //     uint256 margin,
    //     uint256 leverage
    // ) external {
    //     usd.transferFrom(sender, address(this), margin);
    //     _longOpen(user, margin, leverage);
    // }

    // function closeShortList(address[] calldata list) external {
    //     onlyAdmin();
    //     for (uint256 i = 0; i < list.length; i++) {
    //         this.shortClose(list[i]);
    //     }
    // }

    // function closeLongList(address[] calldata list) external {
    //     onlyAdmin();
    //     for (uint256 i = 0; i < list.length; i++) {
    //         this.longClose(list[i]);
    //     }
    // }
}
