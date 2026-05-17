// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { ModifyLiquidityParams } from "v4-core/src/types/PoolOperation.sol";
import { CurrencySettler } from "v4-core/test/utils/CurrencySettler.sol";

/// @title  PoolInitializer
/// @author CodesenSys (https://codesensys.com)
/// @notice One-shot helper for seeding initial liquidity into a compliant V4 pool.
///         Deployed during SeedLiquidity.s.sol, receives tokens, and executes a
///         single unlock callback to add a position.
/// @dev    Implements IUnlockCallback so the PoolManager can call back into this
///         contract within the same transaction. Tokens must be transferred to
///         this contract *before* calling addLiquidity — the callback settles from
///         its own balance (no approval needed).
contract PoolInitializer is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable MANAGER;

    error OnlyPoolManager();

    /// @notice Data passed through manager.unlock → unlockCallback.
    struct LiquidityParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes hookData; // abi.encode(address lp, bytes32[] proof, AccreditationTier tier)
    }

    constructor(IPoolManager _manager) {
        MANAGER = _manager;
    }

    /// @notice Seed a V4 pool position. Tokens must already be held by this contract.
    /// @return delta The balance delta from the liquidity addition.
    function addLiquidity(LiquidityParams calldata params) external returns (BalanceDelta delta) {
        delta = abi.decode(MANAGER.unlock(abi.encode(params)), (BalanceDelta));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Called by the PoolManager as part of the unlock flow. Adds liquidity
    ///      then settles any token debt from this contract's own balance.
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert OnlyPoolManager();

        LiquidityParams memory p = abi.decode(rawData, (LiquidityParams));

        (BalanceDelta delta,) = MANAGER.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: p.liquidityDelta,
                salt: bytes32(0)
            }),
            p.hookData
        );

        // Settle negative deltas (tokens owed to the PoolManager) from this contract's balance.
        // CurrencySettler.settle with payer == address(this) uses transfer(), not transferFrom().
        if (delta.amount0() < 0) {
            p.key.currency0.settle(MANAGER, address(this), uint256(int256(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            p.key.currency1.settle(MANAGER, address(this), uint256(int256(-delta.amount1())), false);
        }

        return abi.encode(delta);
    }
}
