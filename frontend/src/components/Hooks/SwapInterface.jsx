// SPDX-License-Identifier: MIT
import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import { FiTrendingUp, FiAlertCircle, FiLock, FiActivity } from 'react-icons/fi';

import { getSwapQuote, executeSwap, getCurrentTick } from '../../services/hookAPI';

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)"
];

// ─────────────────────────────────────────────────────────────────────────────
// ✅ Official Uniswap V4 Sepolia Architecture Canonical Constants
// ─────────────────────────────────────────────────────────────────────────────
const SWAP_ROUTER_ADDRESS = "0x0c478023803a644c94c4ce1c1e7b9a087e411b0a"; // PoolModifyLiquidityTest Router

const TOKEN_ADDRESSES = {
  eurc: "0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4", // Official EURC Sepolia
  weth: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"  // Official WETH Sepolia
};

const TOKEN_DECIMALS = {
  eurc: 6,
  weth: 18,
};

const PLACEHOLDER_HOOK = "0x88Bb6571DB4f0eb66831E1De0804D033686ab0c0";

const validateHook = (addr) => {
  if (!addr || addr === PLACEHOLDER_HOOK) return false;
  if (!addr.startsWith("0x") || addr.length !== 42) return false;
  try {
    ethers.getAddress(addr);
    return true;
  } catch (e) {
    return false;
  }
};

const SwapInterface = ({ account, hookAddress, poolId, poolManagerAddress, onSwapSuccess, onError }) => {
  const [swapAmount, setSwapAmount] = useState('');
  const [swapDirection, setSwapDirection] = useState('eurcToWeth');
  const [swapLoading, setSwapLoading] = useState(false);
  const [quoteLoading, setQuoteLoading] = useState(false);
  const [swapQuote, setSwapQuote] = useState(null);
  const [error, setError] = useState(null);
  const [poolError, setPoolError] = useState(null);
  const [provider, setProvider] = useState(null);
  const [isApproving, setIsApproving] = useState(false);
  const [currentTick, setLiveTick] = useState(null);
  const [tickLoading, setTickLoading] = useState(false);

  useEffect(() => {
    if (window.ethereum) {
      const browserProvider = new ethers.BrowserProvider(window.ethereum);
      setProvider(browserProvider);
    }
  }, []);

  // Debounced execution context for automatic quotation fetching
  useEffect(() => {
    const isValidHook = validateHook(hookAddress);
    if (swapAmount && !isNaN(swapAmount) && parseFloat(swapAmount) > 0 && account && isValidHook) {
      const timeout = setTimeout(() => { fetchQuote(); }, 600);
      return () => clearTimeout(timeout);
    } else {
      setSwapQuote(null);
      if (!swapAmount || parseFloat(swapAmount) === 0) setError(null);
    }
  }, [swapAmount, swapDirection, account, hookAddress]);

  // Real-time on-chain stream monitoring current tick allocations
  useEffect(() => {
    let isMounted = true;
    let intervalId = null;

    const ON_CHAIN_POOL_ID = "0xde8425f83a965c99cfa40f2ebee4fdde37fd6224743168e3b3b33c72b474e767";
    const targetPoolId = poolId && poolId.startsWith("0x") && poolId.length === 66
      ? poolId
      : ON_CHAIN_POOL_ID;

    const fetchLivePoolTick = async () => {
      if (!provider || !targetPoolId) {
        if (isMounted) setPoolError("Missing Provider or Pool Configuration");
        return;
      }
      try {
        if (isMounted) setTickLoading(true);
        const res = await getCurrentTick(provider, targetPoolId, poolManagerAddress);
        if (!isMounted) return;

        if (res && res.success) {
          setLiveTick(res.tick);
          setPoolError(null);
        } else {
          setLiveTick(0);
          const errMsg = res?.error || "";
          if (errMsg.includes("missing revert data") || errMsg.includes("not initialized")) {
            setPoolError("Pool not initialized yet");
          } else {
            setPoolError(errMsg || "Unable to fetch tick");
          }
        }
      } catch (err) {
        console.error("Tick fetch error:", err);
        if (isMounted) {
          setLiveTick(0);
          setPoolError("Network connection issue");
        }
      } finally {
        if (isMounted) setTickLoading(false);
      }
    };

    const isValidHook = validateHook(hookAddress);
    if (isValidHook && provider) {
      fetchLivePoolTick();
      intervalId = setInterval(fetchLivePoolTick, 30000); // Poll tracking context every 30s
    }

    return () => {
      isMounted = false;
      if (intervalId) clearInterval(intervalId);
    };
  }, [provider, poolId, hookAddress, poolManagerAddress]);

  const fetchQuote = async () => {
    if (!account || !provider) return;
    if (!validateHook(hookAddress)) {
      setError("Hook contract configuration invalid.");
      return;
    }
    try {
      setQuoteLoading(true);
      setError(null);
      
      // Pass execution logic down into backend service matching current 8388608 dynamic architecture
      const result = await getSwapQuote(provider, swapAmount, swapDirection, hookAddress);
      
      if (result && result.success) {
        setSwapQuote(result.quote);
      } else {
        setError(result?.error || "Failed to calculate quote metrics.");
        setSwapQuote(null);
        if (onError && result?.error) onError(result.error);
      }
    } catch (err) {
      setError(err.reason || err.message || "Internal Quotation Error");
      setSwapQuote(null);
    } finally {
      setQuoteLoading(false);
    }
  };

  const handleSwap = async () => {
    if (!account) { setError("Please connect wallet first!"); return; }
    if (!validateHook(hookAddress)) { setError("Hook contract target is unconfigured!"); return; }
    if (!swapAmount || parseFloat(swapAmount) <= 0) { setError("Please enter a valid amount"); return; }

    try {
      setSwapLoading(true);
      setError(null);

      const signer = await provider.getSigner();
      const isEurc = swapDirection === 'eurcToWeth';

      const decimals = isEurc ? TOKEN_DECIMALS.eurc : TOKEN_DECIMALS.weth;
      const sourceTokenAddress = isEurc ? TOKEN_ADDRESSES.eurc : TOKEN_ADDRESSES.weth;
      const amountInUnits = ethers.parseUnits(swapAmount.toString(), decimals);

      const tokenContract = new ethers.Contract(sourceTokenAddress, ERC20_ABI, signer);
      const safeSpenderRouter = ethers.getAddress(SWAP_ROUTER_ADDRESS);

      setError("Checking token allowance balances...");
      const currentAllowance = await tokenContract.allowance(account, safeSpenderRouter);

      // Execute standard token validation clearance mechanics before routing interaction payloads
      if (BigInt(currentAllowance) < BigInt(amountInUnits)) {
        setIsApproving(true);
        setError("Please approve token spending limits...");
        const approveTx = await tokenContract.approve(safeSpenderRouter, ethers.MaxUint256);
        await approveTx.wait();
        setIsApproving(false);
        setError("Token approved! Executing swap...");
      }

      setError(null);
      const result = await executeSwap(signer, swapAmount, swapDirection, hookAddress);

      if (result && result.success) {
        alert(`✅ Swap complete!\nTX: ${result.hash.slice(0, 12)}...`);
        setSwapAmount('');
        setSwapQuote(null);
        if (onSwapSuccess) onSwapSuccess();
      } else {
        setError(result?.error || "Transaction Execution Reverted.");
        if (onError && result?.error) onError(result.error);
      }
    } catch (err) {
      console.error("Swap error:", err);
      let errorMsg = err.reason || err.shortMessage || err.message || "Transaction failed";
      if (errorMsg.includes("user rejected")) {
        errorMsg = "Transaction rejected by user";
      }
      setError(errorMsg);
    } finally {
      setSwapLoading(false);
      setIsApproving(false);
    }
  };

  const setMaxAmount = () => {
    setSwapAmount(swapDirection === 'eurcToWeth' ? '10' : '0.01');
  };

  return (
    <div className="bg-slate-900 rounded-2xl border border-slate-800 shadow-xl p-6">
      <div className="flex justify-between items-center mb-4">
        <h3 className="text-lg font-bold text-slate-100 flex items-center gap-2">
          <FiTrendingUp className="text-purple-400" /> Swap Tokens on Sepolia
        </h3>
        <div className="flex flex-col items-end gap-1">
          <div className="text-xs font-semibold text-purple-400 bg-purple-500/10 px-2.5 py-1 rounded-lg flex items-center gap-1.5 border border-purple-500/20">
            <FiActivity className={`text-purple-400 ${tickLoading ? 'animate-pulse' : ''}`} />
            Current Tick:{' '}
            <span className="font-mono text-slate-200">
              {tickLoading && currentTick === null ? (
                <span className="inline-block w-4 h-2 bg-purple-300/40 animate-pulse rounded"></span>
              ) : currentTick !== null ? currentTick : '0'}
            </span>
          </div>
          {poolError && (
            <span className="text-[10px] text-amber-500 font-medium max-w-[180px] text-right">
              ⚠️ {poolError}
            </span>
          )}
        </div>
      </div>

      <div className="flex gap-2 mb-4">
        {[["eurcToWeth", "EURC → WETH"], ["wethToEurc", "WETH → EURC"]].map(([dir, label]) => (
          <button key={dir}
            type="button"
            onClick={() => { setSwapDirection(dir); setSwapAmount(''); setSwapQuote(null); setError(null); }}
            className={`flex-1 py-2.5 rounded-xl font-semibold text-sm transition-all ${
              swapDirection === dir ? 'bg-purple-600 text-white shadow-md' : 'bg-slate-950 text-slate-400 border border-slate-800 hover:bg-slate-800'
            }`}>
            {label}
          </button>
        ))}
      </div>

      <div className="mb-4">
        <label className="block text-xs font-medium text-slate-400 mb-1">
          Amount ({swapDirection === 'eurcToWeth' ? 'EURC' : 'WETH'})
        </label>
        <input
          type="text"
          inputMode="decimal"
          placeholder="0.0"
          value={swapAmount}
          onChange={(e) => {
            const val = e.target.value.replace(',', '.');
            if (val === '' || /^[0-9]*[.]?[0-9]*$/.test(val)) {
              setSwapAmount(val);
            }
          }}
          className="w-full bg-slate-950 border border-slate-800 rounded-xl px-4 py-3 text-sm focus:outline-none focus:border-purple-500 text-slate-100 font-mono"
        />
        <button type="button" onClick={setMaxAmount} className="text-xs text-purple-400 mt-1.5 hover:underline block font-medium">
          Set Max Test Amount
        </button>
      </div>

      {quoteLoading && (
        <div className="bg-amber-500/10 p-3 rounded-xl mb-4 border border-amber-500/20">
          <div className="text-xs text-amber-400 flex items-center gap-2">
            <span className="animate-spin rounded-full h-3 w-3 border-b-2 border-amber-400 inline-block"></span>
            Fetching quote from PoolManager...
          </div>
        </div>
      )}

      {swapQuote && !quoteLoading && (
        <div className="bg-purple-500/10 p-3 rounded-xl mb-4 border border-purple-500/20">
          <p className="text-xs text-purple-400 font-medium">Estimated Output:</p>
          <p className="text-xl font-bold text-purple-400 font-mono mt-0.5">
            ~{swapQuote} {swapDirection === 'eurcToWeth' ? 'WETH' : 'EURC'}
          </p>
        </div>
      )}

      {error && (
        <div className={`${isApproving ? 'bg-amber-500/10 border-amber-500/20 text-amber-400' : 'bg-red-500/10 border-red-500/20 text-red-400'} border p-3 rounded-xl mb-4`}>
          <div className="text-xs flex items-start gap-2">
            <FiAlertCircle size={14} className="flex-shrink-0 mt-0.5" />
            <span className="break-all">{error}</span>
          </div>
        </div>
      )}

      <div className="flex gap-3">
        <button
          type="button"
          onClick={fetchQuote}
          disabled={quoteLoading || swapLoading || !swapAmount || parseFloat(swapAmount) <= 0 || !account || !validateHook(hookAddress)}
          className="flex-1 py-3 bg-slate-950 hover:bg-slate-800 text-slate-300 border border-slate-800 font-semibold text-sm rounded-xl transition-all disabled:opacity-40 flex items-center justify-center gap-2">
          {quoteLoading ? <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-slate-400"></div> : "💰 Estimate"}
        </button>
        <button
          type="button"
          onClick={handleSwap}
          disabled={swapLoading || quoteLoading || !swapAmount || parseFloat(swapAmount) <= 0 || !account || !validateHook(hookAddress)}
          className="flex-1 py-3 bg-purple-600 hover:bg-purple-700 text-white font-semibold text-sm rounded-xl transition-all shadow-md disabled:opacity-40 flex items-center justify-center gap-2">
          {swapLoading ? <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-white"></div> : isApproving ? <FiLock size={16} /> : <FiTrendingUp size={16} />}
          {isApproving ? "Approving..." : swapLoading ? "Swapping..." : "Swap"}
        </button>
      </div>
    </div>
  );
};

export default SwapInterface;