// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import "./erc20s/yesToken.sol";
import "./erc20s/noToken.sol";

contract MarketplaceFactory is SafeCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    uint256 constant PROTOCOL_FEE = 0.01 ether;
    uint256 constant MARKET_SETUP_FEE = 0.05 ether;

    struct Marketplace {
        uint256 marketplaceID;
        string title;
        address initializer;
        bool resolved;
        uint256 balance;
        uint256 deadline;
        uint8 outcome;
        PoolKey pool;
        address yesToken;
        address noToken;
        uint256 winningSupplyAtResolve;
        uint256 poolWinningBalanceAtResolve;
    }

    uint256 public marketplaceID = 1;
    mapping(uint256 => Marketplace) public marketplaces;
    uint256 public protocolFeeBalance = 0;
    address immutable owner;
    address immutable agent;

    event MarketCreated(
        uint256 marketplaceID,
        string title,
        address initializer,
        uint256 balance,
        uint256 deadline,
        PoolKey pool,
        address yesToken,
        address noToken
    );

    event MarketBet(
        uint256 marketplaceID,
        string title,
        uint256 newBalance,
        address user,
        PoolKey pool
    );

    event MarketResolved(
        uint256 marketplaceID,
        string title,
        uint8 outcome,
        uint256 totalWinningSupply
    );

    error InsufficientSetupFee();
    error TitleNotLongEnough();
    error DeadlineNotLongEnough();
    error OnlyOwnerAccess();
    error InvalidMarketplaceID();
    error InsufficientBetAmount();
    error MarketEnded();
    error BettingClosed();
    error OnlyAgentAccess();
    error IncorrectDecision();
    error MarketUnresolved();
    error RedeemETHFailed();
    error NoTokensToRedeem();

    constructor(
        IPoolManager _poolManager,
        address _agent
    ) SafeCallback(_poolManager) {
        owner = msg.sender;
        agent = _agent;
    }

    function createMarket(
        string calldata _title,
        uint256 _deadline
    ) external payable {
        if (msg.value < MARKET_SETUP_FEE) revert InsufficientSetupFee();

        if (bytes(_title).length < 10) revert TitleNotLongEnough();

        // if (_deadline < block.timestamp + 1 days)
        //     revert DeadlineNotLongEnough(); arbitrum block.timestamp is ahead of the real life one

        uint256 amountAfterFee = msg.value - PROTOCOL_FEE;
        protocolFeeBalance += PROTOCOL_FEE;

        (address newYesToken, address newNoToken) = _mintApproveYesNoTokens(
            marketplaceID,
            amountAfterFee
        );
        PoolKey memory newMarketKey = _createPoolKey(newYesToken, newNoToken);
        _createPoolAddLiquidity(newMarketKey, amountAfterFee);

        Marketplace memory newMarketplace = Marketplace({
            marketplaceID: marketplaceID,
            title: _title,
            initializer: msg.sender,
            resolved: false,
            balance: amountAfterFee,
            deadline: _deadline,
            outcome: 0,
            pool: newMarketKey,
            yesToken: newYesToken,
            noToken: newNoToken,
            winningSupplyAtResolve: 0,
            poolWinningBalanceAtResolve: 0
        });
        marketplaces[marketplaceID] = newMarketplace;

        emit MarketCreated(
            marketplaceID,
            _title,
            msg.sender,
            amountAfterFee,
            _deadline,
            newMarketKey,
            newYesToken,
            newNoToken
        );
        marketplaceID++;
    }

    function getMarket(
        uint256 _marketplaceID
    ) external view returns (Marketplace memory) {
        return marketplaces[_marketplaceID];
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        (PoolKey memory poolKey, uint256 amount, uint256 direction) = abi
            .decode(data, (PoolKey, uint256, uint256));

        if (direction == 0) {
            poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: -887220,
                    tickUpper: 887220,
                    liquidityDelta: int256(amount),
                    salt: bytes32(0)
                }),
                bytes("")
            );

            (int256 delta0, int256 delta1) = _getCurrencyDelta(poolKey);

            poolKey.currency0.settle(
                poolManager,
                address(this),
                uint256(-delta0),
                false
            );

            poolKey.currency1.settle(
                poolManager,
                address(this),
                uint256(-delta1),
                false
            );
        }

        return "";
    }

    function withdrawFees() external {
        if (msg.sender != owner) revert OnlyOwnerAccess();

        // uint256 amount = protocolFeeBalance;
        protocolFeeBalance = 0;
        (bool success, ) = payable(owner).call{value: address(this).balance}( //testing purpeses withdraw all eth
            ""
        );
        require(success, "Transfer of protocolFees failed");
    }

    receive() external payable {}

    function _getCurrencyDelta(
        PoolKey memory _poolKey
    ) internal view returns (int256, int256) {
        int256 delta0 = poolManager.currencyDelta(
            address(this),
            _poolKey.currency0
        );
        int256 delta1 = poolManager.currencyDelta(
            address(this),
            _poolKey.currency1
        );

        return (delta0, delta1);
    }

    function _mintApproveYesNoTokens(
        uint256 _marketplaceID,
        uint256 _amount
    ) internal returns (address, address) {
        YesToken newYesToken = new YesToken(_marketplaceID);
        NoToken newNoToken = new NoToken(_marketplaceID);
        newYesToken.mintYesToken(_amount);
        newYesToken.approve(address(poolManager), _amount);
        newNoToken.mintNoToken(_amount);
        newNoToken.approve(address(poolManager), _amount);

        return (address(newYesToken), address(newNoToken));
    }

    function _createPoolKey(
        address _yesToken,
        address _noToken
    ) internal pure returns (PoolKey memory) {
        (Currency currency0, Currency currency1) = address(_yesToken) <
            address(_noToken)
            ? (
                Currency.wrap(address(_yesToken)),
                Currency.wrap(address(_noToken))
            )
            : (
                Currency.wrap(address(_noToken)),
                Currency.wrap(address(_yesToken))
            );

        return PoolKey(currency0, currency1, 0, 60, IHooks(address(0)));
    }

    function _createPoolAddLiquidity(
        PoolKey memory _newMarketKey,
        uint256 _amount
    ) internal {
        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        poolManager.initialize(_newMarketKey, sqrtPriceX96);
        bytes memory data = abi.encode(
            _newMarketKey,
            _amount,
            0,
            false,
            msg.sender
        );
        poolManager.unlock(data);
    }
}
