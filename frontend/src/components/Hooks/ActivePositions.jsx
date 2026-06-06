import React, { useState, useEffect, useCallback } from 'react';
import { ethers } from 'ethers';
import { FiBox, FiRefreshCw, FiCheckCircle, FiAlertTriangle } from 'react-icons/fi';

// ─────────────────────────────────────────────────────────────────────────────
// ✅ Official Uniswap V4 Sepolia Architecture Network Sync
// ─────────────────────────────────────────────────────────────────────────────
const STATE_VIEW_ADDRESS_RAW = "0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c";
const STATE_VIEW_ADDRESS_SEPOLIA = ethers.getAddress(STATE_VIEW_ADDRESS_RAW);

// Updated to the canonical PoolModifyLiquidityTest address matching your manager
const POOL_MODIFY_ROUTER_ADDRESS = "0x0c478023803a644c94c4ce1c1e7b9a087e411b0a";

const STATE_VIEW_ABI = [
  "function getPositionInfo(bytes32 poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt) external view returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)",
  "function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity)"
];

// Tick Helpers - নিশ্চিত করা হয়েছে যেন সব রিটার্ন খাঁটি integer বা Number হয়
function sortTicks(a, b) {
  const tA = Math.floor(Number(a)), tB = Math.floor(Number(b));
  return { tLower: Math.min(tA, tB), tUpper: Math.max(tA, tB) };
}

function alignTick(tick, spacing) {
  const t = Math.floor(Number(tick));
  const s = Math.floor(Number(spacing));
  const rem = ((t % s) + s) % s;
  if (rem === 0) return t;
  return rem < s / 2 ? t - rem : t + (s - rem);
}

function decodeRevertReason(err) {
  if (err?.reason) return err.reason;
  if (err?.data) {
    try { return ethers.toUtf8String('0x' + err.data.slice(10)); }
    catch { return err.data; }
  }
  return err?.message ?? 'Unknown error';
}

export const ActivePositions = ({
  poolId,
  userAddress,
  stateViewAddress,
  provider,
  tickLower,
  tickUpper,
  tickSpacing = 60,
  salt = ethers.ZeroHash,
}) => {
  const [positionData, setPositionData] = useState(null);
  const [poolState, setPoolState] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [dataSource, setDataSource] = useState(null);

  const fetchPosition = useCallback(async () => {
    // প্যারামিটার ভ্যালিডেশন আরও নিখুঁত করা হয়েছে
    if (!userAddress || !provider || !poolId || tickLower === undefined || tickUpper === undefined) {
      setError('Missing required parameters');
      setLoading(false);
      return;
    }

    try {
      setLoading(true);
      setError(null);

      // ১. টিক সর্টিং এবং স্পেসিং অ্যালাইনমেন্ট প্রসেসিং
      const { tLower: sortedLower, tUpper: sortedUpper } = sortTicks(tickLower, tickUpper);
      const tLower = Number(alignTick(sortedLower, tickSpacing));
      const tUpper = Number(alignTick(sortedUpper, tickSpacing));

      // ২. কন্ট্রাক্ট এড্রেস রিসল্ভিং
      const contractAddress = stateViewAddress 
        ? ethers.getAddress(stateViewAddress)
        : STATE_VIEW_ADDRESS_SEPOLIA;

      const stateView = new ethers.Contract(contractAddress, STATE_VIEW_ABI, provider);

      // ৩. Pool Slot0 ডাটা ফেচিং
      try {
        const slot0 = await stateView.getSlot0(poolId);
        setPoolState({
          sqrtPriceX96: slot0.sqrtPriceX96.toString(),
          tick: Number(slot0.tick),
          lpFee: Number(slot0.lpFee),
        });
      } catch (e) {
        console.warn('⚠️ getSlot0 failed:', e.message);
        setPoolState(null);
      }

      // ৪. পজিশন ডাটা ফেচিং (Checksummed Address ও টাইপ কাস্টেড টিক্স সহ)
      const routerAddress = ethers.getAddress(POOL_MODIFY_ROUTER_ADDRESS);
      const pos = await stateView.getPositionInfo(
        poolId,
        routerAddress,            // ← router is the real owner inside the core manager
        tLower,
        tUpper,
        salt
      );
      
      const liquidity = pos.liquidity.toString();

      if (BigInt(liquidity) > 0n) {
        setPositionData({
          liquidity,
          feeGrowth0: pos.feeGrowthInside0LastX128.toString(),
          feeGrowth1: pos.feeGrowthInside1LastX128.toString(),
          tLower, 
          tUpper,
        });
        setDataSource('live');
      } else {
        setPositionData(null);
        setDataSource('empty');
      }

    } catch (err) {
      console.error('❌ StateView query failed:', err);
      setError(decodeRevertReason(err));
      setDataSource('error');
      setPositionData(null);
    } finally {
      setLoading(false);
    }
  }, [userAddress, provider, poolId, tickLower, tickUpper, salt, tickSpacing, stateViewAddress]);

  useEffect(() => { 
    fetchPosition(); 
  }, [fetchPosition]);

  // ── ১. লোডিং স্টেট রেন্ডার (Dark Theme Consistent) ────────────────────────
  if (loading) return (
    <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 text-center shadow-xl">
      <FiRefreshCw className="text-purple-500 animate-spin mx-auto mb-2" size={24}/>
      <p className="text-xs text-slate-400">Querying StateView contract...</p>
    </div>
  );

  // ── ২. এরর স্টেট রেন্ডার (Dark Theme Consistent) ────────────────────────
  if (dataSource === 'error') return (
    <div className="bg-slate-900 border border-red-900/40 rounded-2xl p-5 space-y-3 shadow-xl">
      <div className="flex items-center gap-2">
        <FiAlertTriangle className="text-red-400" size={16}/>
        <h4 className="text-xs font-bold text-red-400">StateView Query Failed</h4>
      </div>
      <p className="text-[10px] font-mono text-slate-400 bg-slate-950 p-2 rounded break-all">{error}</p>
      <button onClick={fetchPosition} className="text-[10px] text-purple-400 hover:text-purple-300 flex items-center gap-1 font-semibold transition-colors">
        <FiRefreshCw size={10}/> Retry Query
      </button>
    </div>
  );

  // ── ৩. এম্পটি স্টেট রেন্ডার (Fixed: Changed From White to Slate-900 Dark) ──
  if (dataSource === 'empty' || !positionData) return (
    <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 text-center shadow-xl">
      <FiBox className="text-slate-700 mx-auto mb-2" size={32} />
      <h4 className="text-sm font-bold text-slate-200">No Active LP Positions</h4>
      <p className="text-xs text-slate-400 max-w-xs mx-auto mt-1">
        You don't have any liquidity provider positions active inside the selected tick range [{tickLower}, {tickUpper}].
      </p>
    </div>
  );

  // ── ৪. অ্যাক্টিভ পজিশন রেন্ডার (Fixed: Changed From White to Slate-900 Dark) ──
  return (
    <div className="bg-slate-900 border border-slate-800 rounded-2xl p-5 shadow-xl space-y-4">
      <div className="flex justify-between items-center border-b border-slate-800 pb-3">
        <div className="flex items-center gap-2">
          <FiCheckCircle className="text-emerald-400" size={18} />
          <h4 className="text-sm font-bold text-slate-200">Active V4 LP Position</h4>
        </div>
        <span className="text-[10px] bg-emerald-500/10 text-emerald-400 font-semibold px-2 py-0.5 rounded-full border border-emerald-500/20">
          On-Chain Verified
        </span>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div className="bg-slate-950 p-3 rounded-xl border border-slate-800">
          <p className="text-[11px] text-slate-500 font-medium">Liquidity Units (ΔL)</p>
          <p className="text-lg font-bold text-purple-400 font-mono mt-0.5">{positionData.liquidity}</p>
        </div>
        <div className="bg-slate-950 p-3 rounded-xl border border-slate-800">
          <p className="text-[11px] text-slate-500 font-medium">Active Range Spacing</p>
          <p className="text-xs font-semibold text-emerald-400 font-mono mt-2">
            [{positionData.tLower} ↔ {positionData.tUpper}]
          </p>
        </div>
      </div>

      {poolState && (
        <div className="text-[11px] bg-purple-500/10 text-purple-300 border border-purple-500/20 rounded-xl p-3 flex justify-between items-center">
          <span className="font-medium text-slate-400">Current Pool Status:</span>
          <span className="font-mono">Tick: <span className="text-blue-400">{poolState.tick}</span> | Fee: <span className="text-emerald-400">{(poolState.lpFee / 10000).toFixed(2)}%</span></span>
        </div>
      )}
    </div>
  );
};

export default ActivePositions;