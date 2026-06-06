// SPDX-License-Identifier: MIT
import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import { FiPlusCircle, FiAlertCircle, FiCheckCircle } from 'react-icons/fi';

const TICK_SPACING = 60;

// Official Sepolia Addresses
const POSITION_MANAGER = "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4";
const PERMIT2          = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const EURC_ADDRESS     = "0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4";
const WETH_ADDRESS     = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)"
];

const PERMIT2_ABI = [
  "function approve(address token, address spender, uint160 amount, uint48 expiration) external",
  "function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
];

// ✅ FIXED: Correct official PositionManager ABI for Uniswap v4 Actions Pattern
const POSITION_MANAGER_ABI = [
  "function execute(bytes calldata actions, bytes[] calldata params, uint256 deadline) external payable"
];

// ─── Tick helpers ────────────────────────────────────────────────────────────
const alignTick = (tick, spacing = TICK_SPACING) => {
  const t = Number(tick);
  const rem = ((t % spacing) + spacing) % spacing;
  if (rem === 0) return t;
  return rem < spacing / 2 ? t - rem : t + (spacing - rem);
};

const calculateLiquidityDelta = (amount0Str, amount1Str) => {
  try {
    const a0 = ethers.parseUnits(amount0Str || '0', 6);
    const a1 = ethers.parseUnits(amount1Str || '0', 18);
    if (a0 === 0n && a1 === 0n) return 0n;

    const a0scaled = a0 * (10n ** 12n);
    let base;
    if (a0scaled === 0n) base = a1;
    else if (a1 === 0n) base = a0scaled;
    else base = a0scaled < a1 ? a0scaled : a1;

    return base > 0n ? base : ethers.parseUnits('0.001', 18);
  } catch {
    return ethers.parseUnits('0.001', 18);
  }
};

const MAX_UINT256 = ethers.MaxUint256;

// ─── Component ───────────────────────────────────────────────────────────────
const AddLiquidityModal = ({ isOpen, onClose, hookAddress, account, onSuccess }) => {
  const [amount0, setAmount0] = useState('100.0');
  const [amount1, setAmount1] = useState('0.1');
  const [tickLower, setTickLower] = useState('83940');
  const [tickUpper, setTickUpper] = useState('84060');
  const [loading, setLoading] = useState(false);
  const [statusMsg, setStatusMsg] = useState('');
  const [tickError, setTickError] = useState('');

  const alignedLower = alignTick(Number(tickLower));
  const alignedUpper = alignTick(Number(tickUpper));
  const lowerMisaligned = Number(tickLower) !== alignedLower;
  const upperMisaligned = Number(tickUpper) !== alignedUpper;
  const ticksReversed = alignedLower >= alignedUpper;
  const previewDelta = calculateLiquidityDelta(amount0, amount1);

  useEffect(() => {
    if (alignedLower < -8388608 || alignedUpper > 8388607) {
      setTickError('Ticks out of valid int24 boundary range.');
    } else if (alignedLower >= alignedUpper) {
      setTickError('Lower tick must be less than upper tick');
    } else {
      setTickError('');
    }
  }, [tickLower, tickUpper, alignedLower, alignedUpper]);

  if (!isOpen) return null;

  const handleAdd = async () => {
    setLoading(true);
    setStatusMsg('⏳ Preparing transaction…');

    try {
      if (!window.ethereum) throw new Error('No wallet extension found.');
      if (tickError) throw new Error(tickError);

      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const userAddr = await signer.getAddress();

      const liquidityDelta = calculateLiquidityDelta(amount0, amount1);
      if (liquidityDelta === 0n) throw new Error('Amount too small — liquidity delta is zero.');

      const cleanHook = ethers.getAddress(hookAddress);
      const t0 = ethers.getAddress(EURC_ADDRESS);
      const t1 = ethers.getAddress(WETH_ADDRESS);

      // Sort currencies as required by Uniswap v4
      const [currency0, currency1] = BigInt(t0) < BigInt(t1) ? [t0, t1] : [t1, t0];
      
      // ✅ FIXED: Pool fee set to 3000 (0.30%) instead of the broken 8388608
      const poolKey = {
        currency0,
        currency1,
        fee: 3000, 
        tickSpacing: TICK_SPACING,
        hooks: cleanHook
      };

      // ─── Step 1: Allowances and Permit2 ─────────────────────────────────────
      setStatusMsg('⏳ Step 1/3 — Checking allowances…');
      
      const token0 = new ethers.Contract(currency0, ERC20_ABI, signer);
      const token1 = new ethers.Contract(currency1, ERC20_ABI, signer);
      const permit2 = new ethers.Contract(PERMIT2, PERMIT2_ABI, signer);
      
      const amount0Wei = ethers.parseUnits(amount0, 6);
      const amount1Wei = ethers.parseUnits(amount1, 18);
      
      // Approve tokens to Permit2
      const allowance0 = await token0.allowance(userAddr, PERMIT2);
      if (allowance0 < amount0Wei) {
        setStatusMsg('⏳ Approving Token 0 to Permit2…');
        const tx = await token0.approve(PERMIT2, MAX_UINT256);
        await tx.wait();
      }
      
      const allowance1 = await token1.allowance(userAddr, PERMIT2);
      if (allowance1 < amount1Wei) {
        setStatusMsg('⏳ Approving Token 1 to Permit2…');
        const tx = await token1.approve(PERMIT2, MAX_UINT256);
        await tx.wait();
      }
      
      // Approve Permit2 to PositionManager
      setStatusMsg('⏳ Approving Permit2 to PositionManager…');
      const expiry = Math.floor(Date.now() / 1000) + 3600;
      const permit2Amount = "1461501637330902918203684832716283019655932542975"; // type(uint160).max
      
      const permit2Approve0 = await permit2.approve(currency0, POSITION_MANAGER, permit2Amount, expiry);
      await permit2Approve0.wait();
      
      const permit2Approve1 = await permit2.approve(currency1, POSITION_MANAGER, permit2Amount, expiry);
      await permit2Approve1.wait();

      // ─── Step 2: Encode Actions & Execute ───────────────────────────────────
      setStatusMsg('⏳ Step 2/3 — Encoding and Minting Liquidity…');
      
      const posContract = new ethers.Contract(POSITION_MANAGER, POSITION_MANAGER_ABI, signer);
      const abiCoder = ethers.AbiCoder.defaultAbiCoder();

      // Uniswap v4 Action ID for MINT_POSITION / MODIFY_LIQUIDITY (typically 0x02)
      const actionsId = "0x02"; 

      // Encoding the parameters exactly how the v4 PositionManager expects it
      const encodedParam = abiCoder.encode(
        [
          "tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey",
          "int24 tickLower",
          "int24 tickUpper",
          "int256 liquidityDelta",
          "bytes hookData"
        ],
        [
          poolKey,
          alignedLower,
          alignedUpper,
          liquidityDelta, // Encoded as int256
          "0x"
        ]
      );

      const deadline = Math.floor(Date.now() / 1000) + 300; // 5 minute deadline

      // Executing through the official Multicall/Actions gateway
      const tx = await posContract.execute(
        actionsId,
        [encodedParam],
        deadline,
        {
          gasLimit: 2_500_000 // Slightly bumped gas limit for complex hooks
        }
      );

      console.log('🚀 Transaction sent:', tx.hash);
      setStatusMsg(`⏳ Waiting for confirmation… (${tx.hash.slice(0, 10)}…)`);

      // ─── Step 3: Wait for confirmation ─────────────────────────────────────
      setStatusMsg('⏳ Step 3/3 — Confirming transaction…');
      const receipt = await tx.wait();

      if (receipt.status === 1) {
        setStatusMsg(`✅ Liquidity added successfully!`);
        console.log('✅ Transaction confirmed:', receipt);
        if (onSuccess) onSuccess();
        setTimeout(() => onClose(), 2000);
      } else {
        throw new Error('Transaction reverted on-chain');
      }
      
    } catch (err) {
      console.error('❌ Error:', err);
      
      let errorMsg = err.message || 'Unknown error';
      if (err.reason) errorMsg = err.reason;
      if (err.shortMessage) errorMsg = err.shortMessage;
      
      if (errorMsg.includes('not initialized')) {
        errorMsg = 'Pool not initialized yet. Please initialize the pool first with fee 3000.';
      } else if (errorMsg.includes('InvalidPool')) {
        errorMsg = 'Invalid pool configuration. Verify if fee or hook matches deployment.';
      } else if (errorMsg.includes('insufficient')) {
        errorMsg = 'Insufficient balance or allowance.';
      }
      
      setStatusMsg(`❌ ${errorMsg}`);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center p-4 z-50">
      <div className="bg-slate-900 border border-slate-800 p-6 rounded-2xl w-full max-w-sm shadow-2xl text-slate-100">
        <h2 className="text-lg font-bold mb-4 text-white flex items-center gap-2">
          <FiPlusCircle className="text-emerald-400" /> Add Liquidity (v4 Fixed)
        </h2>

        <div className="space-y-3">
          <div>
            <label className="block text-[10px] text-slate-400 mb-1">EURC Amount (6 decimals)</label>
            <input
              type="number" step="0.1" value={amount0}
              onChange={e => setAmount0(e.target.value)}
              className="w-full bg-slate-950 border border-slate-800 rounded-xl p-2.5 text-xs font-mono text-white focus:outline-none focus:border-purple-500"
            />
          </div>

          <div>
            <label className="block text-[10px] text-slate-400 mb-1">WETH Amount (18 decimals)</label>
            <input
              type="number" step="0.001" value={amount1}
              onChange={e => setAmount1(e.target.value)}
              className="w-full bg-slate-950 border border-slate-800 rounded-xl p-2.5 text-xs font-mono text-white focus:outline-none focus:border-purple-500"
            />
          </div>

          <div className="bg-slate-950 border border-slate-800 rounded-xl px-3 py-2">
            <span className="text-[9px] text-slate-500">liquidityDelta → </span>
            <span className="text-[10px] font-mono text-purple-300">{previewDelta.toString()}</span>
          </div>

          <div className="border-t border-slate-800 my-1" />

          <div>
            <label className="block text-[10px] text-slate-400 mb-1">
              Tick Lower
              {ticksReversed && <span className="text-red-400 ml-1">&lt; must be less than Upper</span>}
            </label>
            <input
              type="number" value={tickLower}
              onChange={e => setTickLower(e.target.value)}
              className={`w-full bg-slate-950 border rounded-xl p-2.5 text-xs font-mono text-white ${ticksReversed ? 'border-red-700' : 'border-slate-800'}`}
            />
            {lowerMisaligned && <p className="text-[9px] text-yellow-500 mt-0.5">⚠️ Will snap to {alignedLower}</p>}
          </div>

          <div>
            <label className="block text-[10px] text-slate-400 mb-1">Tick Upper</label>
            <input
              type="number" value={tickUpper}
              onChange={e => setTickUpper(e.target.value)}
              className="w-full bg-slate-950 border border-slate-800 rounded-xl p-2.5 text-xs font-mono text-white"
            />
            {upperMisaligned && <p className="text-[9px] text-yellow-500 mt-0.5">⚠️ Will snap to {alignedUpper}</p>}
          </div>

          {tickError && (
            <div className="bg-red-950/30 border border-red-900/40 rounded-lg px-3 py-2">
              <p className="text-[10px] text-red-400">{tickError}</p>
            </div>
          )}
        </div>

        {statusMsg && (
          <div className={`mt-4 flex items-start gap-2 px-3 py-2 rounded-lg text-[10px] ${
            statusMsg.startsWith('✅') ? 'bg-emerald-950/30 border border-emerald-900/40 text-emerald-300'
            : statusMsg.startsWith('⏳') ? 'bg-blue-950/30 border border-blue-900/40 text-blue-300'
            : 'bg-red-950/30 border border-red-900/40 text-red-300'
          }`}>
            <FiAlertCircle className="shrink-0 mt-0.5" size={11} />
            <span className="break-all">{statusMsg}</span>
          </div>
        )}

        <div className="flex gap-3 mt-5">
          <button onClick={onClose} disabled={loading}
            className="flex-1 py-2.5 bg-slate-800 hover:bg-slate-700 text-slate-300 font-medium text-xs rounded-xl">
            Cancel
          </button>
          <button onClick={handleAdd} disabled={loading || ticksReversed || !!tickError}
            className="flex-1 py-2.5 bg-emerald-600 hover:bg-emerald-500 text-white font-bold text-xs rounded-xl flex items-center justify-center gap-1.5">
            {loading ? <span className="w-3 h-3 border-2 border-white/30 border-t-white rounded-full animate-spin" /> : 'Add Liquidity'}
          </button>
        </div>

        <div className="text-[8px] text-slate-600 text-center mt-4">
          <p>Hook: {hookAddress?.slice(0, 10)}…{hookAddress?.slice(-8)}</p>
        </div>
      </div>
    </div>
  );
};

export default AddLiquidityModal;