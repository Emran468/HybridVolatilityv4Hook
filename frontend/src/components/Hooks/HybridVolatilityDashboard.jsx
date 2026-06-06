// SPDX-License-Identifier: MIT
import React, { useState, useEffect, useCallback } from 'react';
import { ethers } from 'ethers';
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer
} from 'recharts';
import {
  FiActivity, FiTrendingUp, FiDollarSign, FiZap, FiShield,
  FiLink, FiLogOut, FiPlusCircle, FiMinusCircle, FiPlayCircle, FiAlertCircle
} from 'react-icons/fi';
import ActivePositions from "./ActivePositions";
import SwapInterface from "./SwapInterface";
import AddLiquidityModal from "./AddLiquidityModal";

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────
const SEPOLIA_CHAIN_ID            = "0xaa36a7";
const SEPOLIA_RPC_URL             = "https://ethereum-sepolia-rpc.publicnode.com";

// Standard V4 PositionManager & Permit2 addresses
const POSITION_MANAGER_ADDRESS    = "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4";
const PERMIT2_ADDRESS             = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

const ACTUAL_POOL_MANAGER_ADDRESS = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";
const EURC_ADDRESS                = "0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4";
const WETH_ADDRESS                = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";
const TICK_SPACING                = 60;

const TOKEN_DECIMALS = {
  [EURC_ADDRESS.toLowerCase()]: 6,
  [WETH_ADDRESS.toLowerCase()]: 18,
};

const UINT128_MAX = (2n ** 128n) - 1n;

// ─────────────────────────────────────────────────────────────────────────────
// ABIs
// ─────────────────────────────────────────────────────────────────────────────
const POOL_MANAGER_ABI = [
  "function initialize((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96) external returns (int24 tick)"
];

const POSITION_MANAGER_ABI = [
  "function modifyLiquidities(bytes actions, bytes[] params, uint256 deadline) external payable"
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)"
];

const PERMIT2_ABI = [
  "function approve(address token, address spender, uint160 amount, uint48 expiration) external",
  "function allowance(address user, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)"
];

// ─────────────────────────────────────────────────────────────────────────────
// Tick helpers
// ─────────────────────────────────────────────────────────────────────────────
function sortTicks(a, b) {
  const tA = Number(a), tB = Number(b);
  return { tLower: Math.min(tA, tB), tUpper: Math.max(tA, tB) };
}

function alignTick(tick, spacing) {
  const t   = Number(tick);
  const rem = ((t % spacing) + spacing) % spacing;
  if (rem === 0) return t;
  return rem < spacing / 2 ? t - rem : t + (spacing - rem);
}

function validateTicks(lower, upper, spacing = TICK_SPACING) {
  const { tLower: sl, tUpper: su } = sortTicks(lower, upper);
  return {
    tLower    : alignTick(sl, spacing),
    tUpper    : alignTick(su, spacing),
    wasSwapped: Number(lower) > Number(upper),
    wasAligned: sl !== alignTick(sl, spacing) || su !== alignTick(su, spacing),
  };
}

function TickWarning({ value, spacing }) {
  const t = Number(value);
  if (isNaN(t)) return null;
  if (t % spacing !== 0) {
    return (
      <p className="text-[9px] text-yellow-500 mt-0.5">
        ⚠️ Not aligned (÷{spacing}). Will snap to {alignTick(t, spacing)}
      </p>
    );
  }
  return <p className="text-[9px] text-emerald-600 mt-0.5">✅ Aligned</p>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Chart helpers
// ─────────────────────────────────────────────────────────────────────────────
const CustomTooltip = ({ active, payload, label }) => {
  if (!active || !payload?.length) return null;
  const tickData = payload.find(p => p.dataKey === 'tickMovement');
  const feeData  = payload.find(p => p.dataKey === 'fee');
  const feePct   = feeData?.value ? (feeData.value / 10000 * 100).toFixed(2) : '0.30';
  return (
    <div className="bg-slate-900 border border-slate-800 rounded-lg shadow-xl p-3 min-w-[180px] z-50">
      <p className="text-xs text-gray-400 mb-2">{label}</p>
      <div className="space-y-1">
        <div className="flex items-center justify-between gap-3">
          <span className="text-xs text-gray-400">Volatility (Tick Δ):</span>
          <span className="text-xs font-bold text-purple-400">{tickData?.value || 0}</span>
        </div>
        <div className="flex items-center justify-between gap-3">
          <span className="text-xs text-gray-400">Dynamic Fee:</span>
          <span className="text-xs font-bold text-emerald-400">{feePct}%</span>
        </div>
      </div>
    </div>
  );
};

const getFeeInfo = (fee) => {
  if (fee === 8388608 || fee === 3000) {
    return { name: 'Base Fee', percentage: '0.3%', bg: 'bg-emerald-950/20', text: 'text-emerald-400', border: 'border-emerald-900/50' };
  }
  if (fee >= 15000) return { name: 'High Volatile Fee', percentage: '1.5%', bg: 'bg-rose-950/20',   text: 'text-rose-400',    border: 'border-rose-900/50'    };
  if (fee >= 6000)  return { name: 'Mid Volatile Fee',  percentage: '0.6%', bg: 'bg-amber-950/20',  text: 'text-amber-400',   border: 'border-amber-900/50'   };
  return                { name: 'Base Fee',            percentage: '0.3%', bg: 'bg-emerald-950/20', text: 'text-emerald-400', border: 'border-emerald-900/50' };
};

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard component
// ─────────────────────────────────────────────────────────────────────────────
export const HybridVolatilityDashboard = ({
  chartData      = [],
  currentStats   = null,
  poolId         = '0xde8425f83a965c99cfa40f2ebee4fdde37fd6224743168e3b3b33c72b474e767',
  title          = "Uniswap v4 Hybrid Volatility Dashboard",
  hookAddress    = "0x88Bb6571DB4f0eb66831E1De0804D033686ab0c0",
}) => {
  const [activeTab,          setActiveTab]         = useState('dashboard');
  const [internalChartData, setInternalChartData] = useState(chartData);
  const [internalStats,     setInternalStats]     = useState(currentStats);

  const [account,     setAccount]     = useState(null);
  const [balance,     setBalance]     = useState('0.0000');
  const [txLoading,   setTxLoading]   = useState(false);
  const [txStatus,     setTxStatus]    = useState(null); 
  const [initLoading, setInitLoading] = useState(false);
  const [provider,    setProvider]    = useState(null);
  const [isModalOpen, setIsModalOpen] = useState(false);

  const [liquidityDeltaAmount, setLiquidityDeltaAmount] = useState('1000000000000000000');
  const [tickLowerInput,       setTickLowerInput]       = useState('83940');
  const [tickUpperInput,       setTickUpperInput]       = useState('84060');
  const [tickError,            setTickError]            = useState(null);
  const [refreshPositions,     setRefreshPositions]     = useState(0);

  const isSorted = EURC_ADDRESS.toLowerCase() < WETH_ADDRESS.toLowerCase();
  
  const poolKey = {
    currency0  : isSorted ? EURC_ADDRESS : WETH_ADDRESS,
    currency1  : isSorted ? WETH_ADDRESS : EURC_ADDRESS,
    fee        : 8388608, 
    tickSpacing: TICK_SPACING,
    hooks      : hookAddress,
  };

  const fetchLiveBalance = useCallback(async (addr) => {
    try {
      const bp  = new ethers.BrowserProvider(window.ethereum);
      const bal = await bp.getBalance(addr);
      setBalance(ethers.formatEther(bal));
    } catch (e) { console.error('Balance error:', e); }
  }, []);

  useEffect(() => {
    const tL = Number(tickLowerInput);
    const tU = Number(tickUpperInput);
    if (isNaN(tL) || isNaN(tU)) { setTickError('Ticks must be numbers'); return; }
    if (tL === tU)               { setTickError('tickLower and tickUpper must be different'); return; }
    if (tL < -8388608 || tU > 8388607) { setTickError('Ticks out of int24 valid range boundaries'); return; }
    setTickError(null);
  }, [tickLowerInput, tickUpperInput]);

  useEffect(() => { if (chartData?.length)  setInternalChartData(chartData);  }, [chartData]);
  useEffect(() => { if (currentStats)       setInternalStats(currentStats);   }, [currentStats]);

  useEffect(() => {
    if (!window.ethereum) return;
    const bp = new ethers.BrowserProvider(window.ethereum);
    setProvider(bp);
    const onAccountsChanged = async (accounts) => {
      if (accounts.length > 0) {
        setAccount(accounts[0]);
        await fetchLiveBalance(accounts[0]);
      } else {
        setAccount(null);
        setBalance('0.0000');
      }
    };
    window.ethereum.on('accountsChanged', onAccountsChanged);
    return () => window.ethereum?.removeListener?.('accountsChanged', onAccountsChanged);
  }, [fetchLiveBalance]);

  const connectWallet = async () => {
    if (!window.ethereum) return alert('Please install MetaMask!');
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: SEPOLIA_CHAIN_ID }],
      });
    } catch (err) {
      if (err.code === 4902) {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: SEPOLIA_CHAIN_ID,
            chainName: 'Sepolia Testnet',
            rpcUrls: [SEPOLIA_RPC_URL],
            nativeCurrency: { name: 'SepoliaETH', symbol: 'ETH', decimals: 18 },
            blockExplorerUrls: ['https://sepolia.etherscan.io'],
          }],
        });
      }
    }
    const bp       = new ethers.BrowserProvider(window.ethereum);
    const accounts = await bp.send('eth_requestAccounts', []);
    setAccount(accounts[0]);
    setProvider(bp);
    await fetchLiveBalance(accounts[0]);
  };

  const disconnectWallet = () => { setAccount(null); setBalance('0.0000'); };

  const handleInitializePool = async () => {
    if (!account) return alert('Please connect wallet first!');
    try {
      setInitLoading(true);
      const bp     = new ethers.BrowserProvider(window.ethereum);
      const signer = await bp.getSigner();
      const pm     = new ethers.Contract(ACTUAL_POOL_MANAGER_ADDRESS, POOL_MANAGER_ABI, signer);

      const key = {
        currency0  : poolKey.currency0,
        currency1  : poolKey.currency1,
        fee        : Number(poolKey.fee),
        tickSpacing: Number(poolKey.tickSpacing),
        hooks      : poolKey.hooks,
      };

      const sqrtPriceX96 = "3961408125713216879677197516800";

      const tx = await pm.initialize(key, sqrtPriceX96);
      setTxStatus({ type: 'info', msg: `⏳ Init TX sent: ${tx.hash.slice(0, 12)}…` });
      await tx.wait();
      setTxStatus({ type: 'success', msg: '✅ Pool initialized successfully!' });
      await fetchLiveBalance(account);
      setRefreshPositions(p => p + 1);
    } catch (err) {
      console.error(err);
      const KNOWN_ERRORS = {
        '0x7983c051': '⚠️ Pool is already initialized!',
        '0xf9c0959d': '❌ Currencies out of order or equal',
        '0xf3fb0eb9': '❌ Tick spacing too large',
        '0xf4b5c4ef': '❌ Tick spacing too small',
        '0x4db310c3': '❌ Hook address invalid for this pool',
      };
      const errData  = err?.data ?? err?.error?.data;
      const selector = typeof errData === 'string' ? errData.slice(0, 10) : null;
      const msg      = (selector && KNOWN_ERRORS[selector])
        ? KNOWN_ERRORS[selector]
        : 'Init failed: ' + (err.reason || err.shortMessage || err.message);
      setTxStatus({ type: 'error', msg });
    } finally {
      setInitLoading(false);
    }
  };

 const handleLiquidityAction = async (isAdd) => {
  if (!account)   { alert('Please connect wallet first!'); return; }
  if (tickError)  { alert('Please fix tick errors first: ' + tickError); return; }

  const { tLower, tUpper, wasSwapped, wasAligned } = validateTicks(tickLowerInput, tickUpperInput);
  if (wasSwapped) console.warn(`⚠️ Ticks reversed — corrected to [${tLower}, ${tUpper}]`);
  if (wasAligned) console.warn(`⚠️ Ticks snapped to spacing=${TICK_SPACING}: [${tLower}, ${tUpper}]`);

  try {
    setTxLoading(true);
    setTxStatus({ type: 'info', msg: isAdd ? '⏳ Initializing Permit2 Pipeline…' : '⏳ Preparing removal transaction…' });

    const bp     = new ethers.BrowserProvider(window.ethereum);
    const signer = await bp.getSigner();

    // ── Permit2 Pipeline Approvals (only for ADD) ─────────────────────────
    if (isAdd) {
      const t0   = new ethers.Contract(poolKey.currency0, ERC20_ABI, signer);
      const t1   = new ethers.Contract(poolKey.currency1, ERC20_ABI, signer);
      const permit2 = new ethers.Contract(PERMIT2_ADDRESS, PERMIT2_ABI, signer);

      const dec0 = TOKEN_DECIMALS[poolKey.currency0.toLowerCase()] ?? 18;
      const dec1 = TOKEN_DECIMALS[poolKey.currency1.toLowerCase()] ?? 18;
      const req0 = ethers.parseUnits('10000.0', dec0); 
      const req1 = ethers.parseUnits('100.0',   dec1);

      setTxStatus({ type: 'info', msg: '⏳ Checking standard Token-to-Permit2 allowances…' });
      const allow0 = await t0.allowance(account, PERMIT2_ADDRESS).catch(() => 0n);
      if (BigInt(allow0) < req0) {
        setTxStatus({ type: 'info', msg: '⏳ Approving Token 0 to Permit2 Contract…' });
        await (await t0.approve(PERMIT2_ADDRESS, ethers.MaxUint256)).wait();
      }

      const allow1 = await t1.allowance(account, PERMIT2_ADDRESS).catch(() => 0n);
      if (BigInt(allow1) < req1) {
        setTxStatus({ type: 'info', msg: '⏳ Approving Token 1 to Permit2 Contract…' });
        await (await t1.approve(PERMIT2_ADDRESS, ethers.MaxUint256)).wait();
      }

      setTxStatus({ type: 'info', msg: '⏳ Constructing dynamic allowances for PositionManager…' });
      const dynamicExpiry = Math.floor(Date.now() / 1000) + 7200; 
      const permit2MaxUint160 = "1461501637330902918203684832716283019655932542975";

      await (await permit2.approve(poolKey.currency0, POSITION_MANAGER_ADDRESS, permit2MaxUint160, dynamicExpiry)).wait();
      await (await permit2.approve(poolKey.currency1, POSITION_MANAGER_ADDRESS, permit2MaxUint160, dynamicExpiry)).wait();
    }

    // ── Executing interactions via PositionManager V4 Architecture ─────────
    setTxStatus({ type: 'info', msg: '⏳ Encoding Actions and Parameters Context…' });
    const pmContract = new ethers.Contract(POSITION_MANAGER_ADDRESS, POSITION_MANAGER_ABI, signer);
    
    const key = {
      currency0  : poolKey.currency0,
      currency1  : poolKey.currency1,
      fee        : Number(poolKey.fee),
      tickSpacing: Number(poolKey.tickSpacing),
      hooks      : poolKey.hooks,
    };

    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    
    // ✅ FIXED: Use single action in hex string
    const actionsPayload = isAdd ? "0x00" : "0x01";

    // ✅ FIXED: Properly encode delta amount
    let deltaPayload;
    if (isAdd) {
      // For add: positive delta
      deltaPayload = BigInt(liquidityDeltaAmount);
    } else {
      // For remove: negative delta (needs to be converted properly)
      // In Uniswap v4, liquidityDelta for burn is also positive uint256
      deltaPayload = BigInt(liquidityDeltaAmount);
    }

    // ✅ FIXED: Proper params encoding without extra fields
    const mintParams = abiCoder.encode(
      [
        'tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey',
        'int24 tickLower',
        'int24 tickUpper',
        'uint256 liquidityDelta',
        'uint128 amount0Max',
        'uint128 amount1Max',
        'address recipient',
        'bytes hookData'
      ],
      [
        key,
        tLower,
        tUpper,
        deltaPayload,
        UINT128_MAX,
        UINT128_MAX,
        account,
        '0x'  // empty hookData
      ]
    );

    // ✅ FIXED: Single param for single action
    const paramsArray = [mintParams];
    const deadline    = Math.floor(Date.now() / 1000) + 1200;

    // Log for debugging
    console.log('📤 Sending transaction with:');
    console.log('  actionsPayload:', actionsPayload);
    console.log('  paramsArray length:', paramsArray.length);
    console.log('  tLower:', tLower);
    console.log('  tUpper:', tUpper);
    console.log('  deltaPayload:', deltaPayload.toString());

    let gasLimit;
    try {
      const est = await pmContract.modifyLiquidities.estimateGas(actionsPayload, paramsArray, deadline);
      gasLimit  = est * 130n / 100n;
      console.log('  estimated gas:', est.toString(), '-> final:', gasLimit.toString());
    } catch (gasErr) {
      console.warn('Gas estimation failed:', gasErr);
      gasLimit = 2_000_000n;
    }

    const tx = await pmContract.modifyLiquidities(actionsPayload, paramsArray, deadline, { gasLimit });
    setTxStatus({ type: 'info', msg: `⏳ Broadcasting Tx: ${tx.hash.slice(0, 12)}…` });
    
    const receipt = await tx.wait();

    if (receipt.status === 1) {
      setTxStatus({ type: 'success', msg: `✅ Liquidity Successfully Delta-Adjusted On-Chain!` });
      setTickLowerInput(String(tLower));
      setTickUpperInput(String(tUpper));
      await fetchLiveBalance(account);
      setRefreshPositions(p => p + 1);
    } else {
      setTxStatus({ type: 'error', msg: '❌ Transaction Execution Interrupted and Reverted On-Chain.' });
    }
  } catch (err) {
    console.error('Modify Liquidity Pipeline Failure:', err);
    
    // Better error parsing
    let errorMsg = err.message || 'Unknown error';
    if (err.reason) errorMsg = err.reason;
    if (err.shortMessage) errorMsg = err.shortMessage;
    if (err.data && typeof err.data === 'string') {
      const selector = err.data.slice(0, 10);
      if (selector === '0x08c379a0') {
        // This is a revert with a message
        const decodedMsg = ethers.decodeBytes32String('0x' + err.data.slice(10));
        errorMsg = decodedMsg;
      }
    }
    
    setTxStatus({ type: 'error', msg: '❌ ' + errorMsg });
  } finally {
    setTxLoading(false);
  }
};
  const handleSwapSuccess = async () => {
    if (account) await fetchLiveBalance(account);
    setRefreshPositions(p => p + 1);
  };

  const feeInfo        = getFeeInfo(internalStats?.currentFee ?? 8388608);
  const { tLower: validatedLower, tUpper: validatedUpper } = validateTicks(tickLowerInput, tickUpperInput);

  const statusColour = txStatus?.type === 'success'
    ? 'bg-emerald-950/40 border-emerald-900/50 text-emerald-300'
    : txStatus?.type === 'error'
    ? 'bg-red-950/40 border-red-900/50 text-red-300'
    : 'bg-blue-950/40 border-blue-900/50 text-blue-300';

  return (
    <div className="min-h-screen w-full bg-slate-950 p-4 md:p-6 text-slate-100 font-sans">
      <div className="max-w-7xl mx-auto w-full space-y-6">

        {/* HEADER */}
        <div className="bg-gradient-to-r from-purple-900/40 via-indigo-900/40 to-slate-900 border border-slate-800 rounded-2xl p-6 shadow-2xl">
          <div className="flex justify-between items-start flex-wrap md:flex-nowrap gap-4">
            <div>
              <div className="flex items-center gap-2 mb-2">
                <FiZap className="text-purple-400 animate-pulse" size={18} />
                <span className="text-xs font-mono bg-purple-500/10 border border-purple-500/20 px-2 py-0.5 rounded text-purple-300">
                  Sepolia Testnet
                </span>
              </div>
              <h1 className="text-xl md:text-2xl font-bold tracking-tight text-white">{title}</h1>
            </div>
            <div className="bg-slate-900/80 border border-slate-800 rounded-xl px-4 py-2 min-w-[220px]">
              <div className="text-[10px] text-slate-500 font-medium">PositionManager (V4)</div>
              <div className="text-xs font-mono tracking-wider text-purple-300 break-all mt-0.5">
                {POSITION_MANAGER_ADDRESS}
              </div>
            </div>
          </div>
        </div>

        {/* TABS */}
        <div className="flex border border-slate-800 bg-slate-900/50 p-1 rounded-xl gap-2 w-max">
          {[['dashboard','📊 Analytics'],['liquidity','💧 Liquidity Pool'],['swap','🔄 Swap tokens']].map(([tab, label]) => (
            <button key={tab} onClick={() => setActiveTab(tab)}
              className={`px-4 py-1.5 rounded-lg text-xs font-semibold transition-all ${
                activeTab === tab ? 'bg-purple-600 text-white shadow-md' : 'text-slate-400 hover:text-white'
              }`}>
              {label}
            </button>
          ))}
        </div>

        {/* ANALYTICS TAB */}
        {activeTab === 'dashboard' && (
          <div className="space-y-6">
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              <div className={`${feeInfo.bg} rounded-xl p-4 border ${feeInfo.border} shadow-sm`}>
                <div className="flex items-center justify-between mb-1">
                  <span className="text-xs text-slate-400">Current Fee Tier</span>
                  <FiDollarSign className={feeInfo.text} size={14}/>
                </div>
                <div className={`text-2xl font-bold ${feeInfo.text}`}>{feeInfo.percentage}</div>
              </div>
              <div className="bg-slate-900 border border-slate-800 rounded-xl p-4">
                <div className="flex items-center justify-between mb-1">
                  <span className="text-xs text-slate-400">Abs Volatility</span>
                  <FiTrendingUp className="text-purple-400" size={14}/>
                </div>
                <div className="text-2xl font-bold text-purple-400">{internalStats?.currentVolatility || 0}</div>
              </div>
              <div className="bg-slate-900 border border-slate-800 rounded-xl p-4">
                <div className="flex items-center justify-between mb-1">
                  <span className="text-xs text-slate-400">Live Pool Tick</span>
                  <FiActivity className="text-blue-400" size={14}/>
                </div>
                <div className="text-2xl font-bold text-blue-400">{internalStats?.lastTick || 0}</div>
              </div>
              <div className="bg-slate-900 border border-slate-800 rounded-xl p-4">
                <div className="flex items-center justify-between mb-1">
                  <span className="text-xs text-slate-400">Session Swaps</span>
                  <FiShield className="text-emerald-400" size={14}/>
                </div>
                <div className="text-2xl font-bold text-emerald-400">{internalStats?.totalSwaps || 0}</div>
              </div>
            </div>

            <div className="bg-slate-900 border border-slate-800 rounded-2xl overflow-hidden shadow-xl">
              <div className="p-4 border-b border-slate-800">
                <span className="text-sm font-semibold text-slate-200">Real-Time On-Chain Metrics</span>
              </div>
              <div className="p-4 min-h-[360px]">
                <ResponsiveContainer width="100%" height={320}>
                  <LineChart data={internalChartData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#1e293b" opacity={0.3}/>
                    <XAxis dataKey="time" stroke="#64748b" fontSize={10}/>
                    <YAxis yAxisId="left"  stroke="#8b5cf6" fontSize={10}/>
                    <YAxis yAxisId="right" orientation="right" stroke="#10b981" fontSize={10}/>
                    <Tooltip content={<CustomTooltip/>}/>
                    <Line yAxisId="left"  type="monotone" dataKey="tickMovement" stroke="#8b5cf6" strokeWidth={2} dot={false}/>
                    <Line yAxisId="right" type="monotone" dataKey="fee"          stroke="#10b981" strokeWidth={2} dot={false}/>
                  </LineChart>
                </ResponsiveContainer>
              </div>
            </div>
          </div>
        )}

        {/* LIQUIDITY TAB */}
        {activeTab === 'liquidity' && (
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <div className="lg:col-span-2 space-y-6">

              {/* Wallet hub */}
              <div className="bg-slate-900 border border-slate-800 p-5 rounded-2xl flex justify-between items-center shadow-lg">
                <h3 className="text-sm font-bold flex items-center gap-2">
                  <FiLink className="text-purple-400"/> Web3 Wallet Hub
                </h3>
                {!account ? (
                  <button onClick={connectWallet}
                    className="px-4 py-2 bg-purple-600 hover:bg-purple-700 text-white font-bold text-xs rounded-xl shadow-md transition-all">
                    Connect Wallet
                  </button>
                ) : (
                  <div className="flex items-center gap-3 bg-slate-950 p-2 rounded-xl border border-slate-800">
                    <div className="text-right">
                      <p className="text-xs font-mono font-bold text-slate-300">
                        {account.slice(0,6)}…{account.slice(-4)}
                      </p>
                      <p className="text-[10px] text-emerald-400 font-bold">
                        Bal: {parseFloat(balance).toFixed(4)} ETH
                      </p>
                    </div>
                    <button onClick={disconnectWallet}
                      className="p-2 bg-red-950/40 text-red-400 hover:bg-red-900/30 rounded-lg transition-all">
                      <FiLogOut size={14}/>
                    </button>
                  </div>
                )}
              </div>

              {/* Status banner */}
              {txStatus && (
                <div className={`flex items-start gap-2 px-4 py-3 rounded-xl border text-xs ${statusColour}`}>
                  <FiAlertCircle size={14} className="shrink-0 mt-0.5"/>
                  <span>{txStatus.msg}</span>
                  <button onClick={() => setTxStatus(null)}
                    className="ml-auto text-xs opacity-60 hover:opacity-100">✕</button>
                </div>
              )}

              {/* Pool actions */}
              {account && (
                <div className="bg-gradient-to-br from-slate-900 to-indigo-950/30 border border-purple-900/40 p-5 rounded-2xl shadow-xl flex items-center justify-between flex-wrap gap-4">
                  <div className="space-y-0.5">
                    <h4 className="text-sm font-bold text-white flex items-center gap-2">
                      <FiPlayCircle className="text-emerald-400"/> Pool Liquidity Actions
                    </h4>
                    <p className="text-[11px] text-slate-400">
                      Initialize pool first, then add liquidity below or via the modal.
                    </p>
                  </div>
                  <div className="flex items-center gap-3">
                    <button onClick={handleInitializePool} disabled={initLoading}
                      className="px-4 py-2 bg-gradient-to-r from-emerald-600 to-teal-600 hover:from-emerald-500 hover:to-teal-500 text-white font-bold text-xs rounded-xl shadow-lg transition-all flex items-center gap-2 disabled:opacity-50">
                      {initLoading ? 'Initializing…' : '🚀 Initialize Pool'}
                    </button>
                    <button onClick={() => setIsModalOpen(true)}
                      className="px-4 py-2 bg-purple-600 hover:bg-purple-500 text-white font-bold text-xs rounded-xl shadow-lg transition-all flex items-center gap-1.5">
                      <FiPlusCircle size={14}/> Add via Modal
                    </button>
                  </div>
                </div>
              )}

              {/* Inline delta controller */}
              {account && (
                <div className="bg-slate-900 border border-slate-800 p-6 rounded-2xl shadow-xl space-y-4">
                  <h3 className="text-sm font-bold text-slate-200">Inline Delta Controller (PositionManager V4)</h3>

                  {tickError && (
                    <div className="flex items-center gap-2 bg-red-950/30 border border-red-900/40 px-3 py-2 rounded-lg">
                      <FiAlertCircle className="text-red-400 shrink-0" size={13}/>
                      <p className="text-[10px] text-red-400">{tickError}</p>
                    </div>
                  )}

                  <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <div>
                      <label className="block text-[10px] text-slate-500 mb-1">Liquidity Delta (units)</label>
                      <input type="text" value={liquidityDeltaAmount}
                        onChange={e => setLiquidityDeltaAmount(e.target.value)}
                        className="w-full bg-slate-950 border border-slate-800 text-slate-200 px-3 py-2 rounded-xl text-xs font-mono focus:outline-none focus:border-purple-500"/>
                    </div>
                    <div>
                      <label className="block text-[10px] text-slate-500 mb-1">
                        Tick Lower
                        {Number(tickLowerInput) > Number(tickUpperInput) && (
                          <span className="text-red-400 ml-1">← must be &lt; Upper</span>
                        )}
                      </label>
                      <input type="number" value={tickLowerInput}
                        onChange={e => setTickLowerInput(e.target.value)}
                        className={`w-full bg-slate-950 border text-slate-200 px-3 py-2 rounded-xl text-xs font-mono focus:outline-none focus:border-purple-500 ${
                          Number(tickLowerInput) > Number(tickUpperInput) ? 'border-red-700' : 'border-slate-800'
                        }`}/>
                      <TickWarning value={tickLowerInput} spacing={TICK_SPACING}/>
                    </div>
                    <div>
                      <label className="block text-[10px] text-slate-500 mb-1">Tick Upper</label>
                      <input type="number" value={tickUpperInput}
                        onChange={e => setTickUpperInput(e.target.value)}
                        className={`w-full bg-slate-950 border text-slate-200 px-3 py-2 rounded-xl text-xs font-mono focus:outline-none focus:border-purple-500 ${
                          Number(tickLowerInput) > Number(tickUpperInput) ? 'border-red-700' : 'border-slate-800'
                        }`}/>
                      <TickWarning value={tickUpperInput} spacing={TICK_SPACING}/>
                    </div>
                  </div>

                  {(validateTicks(tickLowerInput, tickUpperInput).wasSwapped ||
                    validateTicks(tickLowerInput, tickUpperInput).wasAligned) && (
                    <p className="text-[9px] text-blue-400 bg-blue-950/20 border border-blue-900/30 px-2.5 py-1.5 rounded">
                      ℹ️ Will auto-correct to [{validatedLower}, {validatedUpper}] before TX
                    </p>
                  )}

                  <div className="flex gap-4">
                    <button onClick={() => handleLiquidityAction(true)}
                      disabled={txLoading || !!tickError}
                      className="flex-1 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-bold text-xs rounded-xl flex items-center justify-center gap-2 disabled:opacity-40 transition-all">
                      <FiPlusCircle size={14}/>
                      {txLoading ? 'Executing…' : 'Add Delta'}
                    </button>
                    <button onClick={() => handleLiquidityAction(false)}
                      disabled={txLoading || !!tickError}
                      className="flex-1 py-2.5 bg-rose-600 hover:bg-rose-700 text-white font-bold text-xs rounded-xl flex items-center justify-center gap-2 disabled:opacity-40 transition-all">
                      <FiMinusCircle size={14}/>
                      {txLoading ? 'Executing…' : 'Remove Delta'}
                    </button>
                  </div>
                </div>
              )}
            </div>

            {/* Active positions panel */}
            <div className="w-full">
              {account && provider ? (
                <ActivePositions
                  poolId={poolId}
                  userAddress={account}
                  poolHelperAddress={ACTUAL_POOL_MANAGER_ADDRESS}
                  provider={provider}
                  tickLower={validatedLower}
                  tickUpper={validatedUpper}
                  tickSpacing={TICK_SPACING}
                  key={`${refreshPositions}-${validatedLower}-${validatedUpper}`}
                />
              ) : (
                <div className="bg-slate-900 border border-slate-800 border-dashed p-6 text-center text-xs text-slate-500 rounded-2xl">
                  Connect wallet to view live LP positions.
                </div>
              )}
            </div>
          </div>
        )}

        {/* SWAP TAB */}
        {activeTab === 'swap' && (
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <div className="lg:col-span-2">
              <SwapInterface
                account={account}
                hookAddress={hookAddress}
                poolId={poolId}
                poolManagerAddress={ACTUAL_POOL_MANAGER_ADDRESS}
                onSwapSuccess={handleSwapSuccess}
              />
            </div>
          </div>
        )}

      </div>

      <AddLiquidityModal
        isOpen={isModalOpen}
        onClose={() => setIsModalOpen(false)}
        hookAddress={hookAddress}
        account={account}
        onSuccess={handleSwapSuccess}
      />
    </div>
  );
};

export default HybridVolatilityDashboard;