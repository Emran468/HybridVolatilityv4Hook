import { useState, useEffect, useCallback } from 'react';
// ✅ সঠিক ইম্পোর্ট - default import (কারণ hookAPI default export করেছে)
import hookAPI from './services/hookAPI';
import HybridVolatilityDashboard from './components/Hooks/HybridVolatilityDashboard';

// ✅ Sepolia Testnet - আপনার সঠিক কন্ট্রাক্ট তথ্য
const REAL_POOL_ID = "0xde8425f83a965c99cfa40f2ebee4fdde37fd6224743168e3b3b33c72b474e767";
const YOUR_HOOK_ADDRESS = "0x88Bb6571DB4f0eb66831E1De0804D033686ab0c0"; // ✅ আপনার হুক অ্যাড্রেস

function App() {
  const [chartData, setChartData] = useState([]);
  const [currentStats, setCurrentStats] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const loadHookData = useCallback(async () => {
    try {
      if (!currentStats) setLoading(true);
      
      // hookAPI ব্যবহার করে ডেটা লোড করুন
      const data = await hookAPI.getHookData(REAL_POOL_ID);
      console.log('Real Data Loaded From Express API:', data);

      if (data && data.success) {
        // চার্টের জন্য হিস্ট্রি
        setChartData(data.history || []);
        
        // ড্যাশবোর্ডের জন্য স্ট্যাটাস
        setCurrentStats({
          currentFee: data.status?.currentFee ?? 3000,
          currentVolatility: data.status?.currentVolatility ?? 0,
          lastTick: data.status?.currentTick ?? 0,
          totalSwaps: data.history?.length ?? 0
        });
        
        setError(null);
      } else {
        console.warn("API returned:", data);
        // ফallback ডেটা
        setChartData([]);
        setCurrentStats({
          currentFee: 3000,
          currentVolatility: 0,
          lastTick: 0,
          totalSwaps: 0
        });
      }
    } catch (err) {
      console.error("API Fetch Error:", err);
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [currentStats]);

  useEffect(() => {
    loadHookData();
    const interval = setInterval(() => {
      loadHookData();
    }, 30000); // প্রতি 30 সেকেন্ডে আপডেট

    return () => clearInterval(interval);
  }, [loadHookData]);

  // Loading Screen
  if (loading && !currentStats) {
    return (
      <div className="flex justify-center items-center h-screen bg-slate-950">
        <div className="text-center">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-purple-500 mx-auto mb-4"></div>
          <p className="text-sm text-slate-400 font-medium">Connecting to Sepolia Testnet...</p>
          <p className="text-xs text-slate-600 mt-2 font-mono">{YOUR_HOOK_ADDRESS.slice(0, 20)}...</p>
        </div>
      </div>
    );
  }

  // Error Screen
  if (error && !currentStats) {
    return (
      <div className="flex justify-center items-center h-screen bg-slate-950">
        <div className="text-center text-red-400 p-6 bg-slate-900 rounded-xl shadow-md border border-slate-800 max-w-sm mx-4">
          <p className="font-bold text-lg mb-1 text-white">Connection Failed</p>
          <p className="text-xs text-slate-400 mb-4">Make sure your backend server is running on port 3001</p>
          <p className="text-sm font-mono bg-slate-950 p-2 rounded border border-slate-700 mb-4 break-all text-slate-300">{error}</p>
          <button 
            onClick={loadHookData}
            className="w-full px-4 py-2 bg-purple-600 text-white rounded-lg font-medium text-sm hover:bg-purple-500 transition"
          >
            Reconnect Server
          </button>
        </div>
      </div>
    );
  }

  // Main Dashboard Render
  return (
    <HybridVolatilityDashboard
      chartData={chartData}          
      currentStats={currentStats}    
      poolId={REAL_POOL_ID}          
      title="Uniswap v4 Hybrid Volatility Hook (Sepolia)"
      hookAddress={YOUR_HOOK_ADDRESS}  // ✅ আপনার হুক অ্যাড্রেস
    />
  );
}

export default App;