import { useMemo, useState, type PointerEvent } from "react";
import { formatValuation } from "@/lib/money";

type DayRow = [string, { income: number; expense: number }];
type ChartMode = "daily" | "cumulative";

type ChartPoint = {
  date: string;
  income: number;
  expense: number;
  net: number;
  positionX: number;
  incomeY: number;
  expenseY: number;
  netY: number;
};

const chartWidth = 960;
const chartHeight = 300;
const margin = { top: 14, right: 24, bottom: 48, left: 62 };
const plotWidth = chartWidth - margin.left - margin.right;
const plotHeight = chartHeight - margin.top - margin.bottom;
const plotBottom = margin.top + plotHeight;
const baselineValue = 0;

export function HomeDailyTrendChart({ rows, valuationCurrency, mode = "daily" }: { rows: DayRow[]; valuationCurrency: string; mode?: ChartMode }) {
  const [activeIndex, setActiveIndex] = useState<number | null>(null);
  const model = useMemo(() => buildChartModel(rows, mode), [rows, mode]);
  const activePoint = activeIndex == null ? null : model.points[activeIndex] ?? null;
  const chartCopy = mode === "cumulative"
    ? { title: "累计收支趋势", desc: "平滑折线表示本期累计收入、累计支出和累计净额。", income: "累计收入", expense: "累计支出", net: "累计净额" }
    : { title: "日收支节奏", desc: "平滑折线表示每日收入、每日支出和每日净收入。", income: "收入", expense: "支出", net: "净收入" };
  const titleId = `home-${mode}-chart-title`;
  const descId = `home-${mode}-chart-desc`;
  const fillId = `home-${mode}-chart-income-fill`;

  function updateActivePoint(event: PointerEvent<SVGRectElement>) {
    if (!model.points.length) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const ratio = (event.clientX - rect.left) / Math.max(rect.width, 1);
    const pointerX = ratio * chartWidth;
    const nearest = model.points.reduce((best, point, index) => {
      const distance = Math.abs(point.positionX - pointerX);
      return distance < best.distance ? { index, distance } : best;
    }, { index: 0, distance: Number.POSITIVE_INFINITY });
    setActiveIndex(nearest.index);
  }

  return <div className="home-daily-chart relative h-full min-w-0" data-active={activePoint ? "true" : "false"} data-mode={mode}>
    <svg className="h-full w-full" viewBox={`0 0 ${chartWidth} ${chartHeight}`} role="img" aria-labelledby={`${titleId} ${descId}`} preserveAspectRatio="none">
      <title id={titleId}>{chartCopy.title}</title>
      <desc id={descId}>{chartCopy.desc}</desc>

      <rect x={margin.left} y={margin.top} width={plotWidth} height={plotHeight} className="home-daily-chart-plot" />

      <defs>
        <linearGradient id={fillId} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" className="home-daily-chart-fill-strong" />
          <stop offset="100%" className="home-daily-chart-fill-clear" />
        </linearGradient>
      </defs>

      {model.valueTicks.map((tick) => {
        const y = scaleValue(tick, model.minValue, model.maxValue, plotBottom, plotHeight);
        return <g key={`expense-${tick}`}>
          <line x1={margin.left} x2={chartWidth - margin.right} y1={y} y2={y} className="home-daily-chart-grid" vectorEffect="non-scaling-stroke" />
          <text x={margin.left - 12} y={y + 4} textAnchor="end" className="home-daily-chart-axis-label">{compactMoney(tick)}</text>
        </g>;
      })}

      <line x1={margin.left} x2={chartWidth - margin.right} y1={model.baselineY} y2={model.baselineY} className="home-daily-chart-baseline" vectorEffect="non-scaling-stroke" />

      {model.dateLabels.map(({ index, label }) => {
        const point = model.points[index];
        return point ? <text key={`${point.date}-${label}`} x={point.positionX} y={chartHeight - 10} textAnchor="middle" className="home-daily-chart-axis-label">{label}</text> : null;
      })}

      {model.incomeAreaPath && <path d={model.incomeAreaPath} className="home-daily-chart-area" style={{ fill: `url(#${fillId})` }} />}
      {model.incomeLinePath && <path d={model.incomeLinePath} className="home-daily-chart-line home-daily-chart-line-income" vectorEffect="non-scaling-stroke" />}
      {model.expenseLinePath && <path d={model.expenseLinePath} className="home-daily-chart-line home-daily-chart-line-expense" vectorEffect="non-scaling-stroke" />}
      {model.netLinePath && <path d={model.netLinePath} className="home-daily-chart-line home-daily-chart-line-net" vectorEffect="non-scaling-stroke" />}

      {model.points.map((point, index) => point.income > 0 ? <circle
        key={`${point.date}-income`}
        cx={point.positionX}
        cy={point.incomeY}
        r={index === activeIndex ? 4 : 2.5}
        className={index === activeIndex ? "home-daily-chart-dot home-daily-chart-dot-active" : "home-daily-chart-dot"}
        vectorEffect="non-scaling-stroke"
      >
        <title>{`${point.date} 收入 ${formatValuation(point.income, valuationCurrency)}`}</title>
      </circle> : null)}

      {activePoint && <g className="home-daily-chart-cursor">
        <rect x={activePoint.positionX - model.stepWidth / 2} y={margin.top} width={model.stepWidth} height={plotHeight} />
        <line x1={activePoint.positionX} x2={activePoint.positionX} y1={margin.top} y2={plotBottom} vectorEffect="non-scaling-stroke" />
      </g>}

      <rect
        x={margin.left}
        y={margin.top}
        width={plotWidth}
        height={plotHeight}
        fill="transparent"
        onPointerMove={updateActivePoint}
        onPointerLeave={() => setActiveIndex(null)}
      />
    </svg>
    <div className="home-daily-chart-legend">
      <span><i className="home-daily-chart-legend-key home-daily-chart-legend-income" />{chartCopy.income}</span>
      <span><i className="home-daily-chart-legend-key home-daily-chart-legend-expense" />{chartCopy.expense}</span>
      <span><i className="home-daily-chart-legend-key home-daily-chart-legend-net" />{chartCopy.net}</span>
    </div>
    {activePoint && <div className="home-daily-chart-tooltip" style={{ left: `${activePoint.positionX / chartWidth * 100}%`, top: `${Math.max(8, activePoint.incomeY / chartHeight * 100)}%` }}>
      <div className="text-[10px] tabular-nums text-stone">{activePoint.date}</div>
      <div className="mt-1 grid gap-0.5 text-xs tabular-nums text-ink">
        <span>{chartCopy.expense} {formatValuation(activePoint.expense, valuationCurrency)}</span>
        <span>{chartCopy.income} {formatValuation(activePoint.income, valuationCurrency)}</span>
        <span>{chartCopy.net} {formatValuation(activePoint.net, valuationCurrency)}</span>
      </div>
    </div>}
  </div>;
}

function buildChartModel(rows: DayRow[], mode: ChartMode) {
  let cumulativeIncome = 0;
  let cumulativeExpense = 0;
  const rawPoints = rows.map(([date, value]) => {
    const dailyIncome = value.income / 100;
    const dailyExpense = value.expense / 100;
    if (mode === "cumulative") {
      cumulativeIncome += dailyIncome;
      cumulativeExpense += dailyExpense;
      return { date, income: cumulativeIncome, expense: cumulativeExpense, net: cumulativeIncome - cumulativeExpense };
    }
    return { date, income: dailyIncome, expense: dailyExpense, net: dailyIncome - dailyExpense };
  });
  const maxRaw = rawPoints.reduce((max, point) => Math.max(max, point.income, point.expense, point.net, baselineValue), baselineValue);
  const minRaw = rawPoints.reduce((min, point) => Math.min(min, point.net, baselineValue), baselineValue);
  const maxValue = niceMax(maxRaw);
  const minValue = mode === "daily" ? niceDailyMin(minRaw, maxValue) : niceMin(minRaw, maxValue);
  const count = Math.max(rawPoints.length, 1);
  const step = plotWidth / count;
  const points: ChartPoint[] = rawPoints.map((point, index) => {
    const positionX = margin.left + step * index + step / 2;
    const incomeY = scaleValue(point.income, minValue, maxValue, plotBottom, plotHeight);
    const expenseY = scaleValue(point.expense, minValue, maxValue, plotBottom, plotHeight);
    const netY = scaleValue(point.net, minValue, maxValue, plotBottom, plotHeight);
    return { ...point, positionX, incomeY, expenseY, netY };
  });
  const baselineY = scaleValue(baselineValue, minValue, maxValue, plotBottom, plotHeight);
  const incomeLinePath = buildSmoothPath(points, "incomeY");
  const expenseLinePath = buildSmoothPath(points, "expenseY");
  const netLinePath = buildSmoothPath(points, "netY");
  const incomeAreaPath = buildAreaPath(points, "incomeY", baselineY);
  const labelEvery = Math.max(1, Math.ceil(points.length / 8));
  const dateLabels = points.map((point, index) => ({ index, label: point.date.slice(5) })).filter((_, index) => index % labelEvery === 0 || index === points.length - 1);
  return {
    points,
    incomeLinePath,
    expenseLinePath,
    netLinePath,
    incomeAreaPath,
    minValue,
    maxValue,
    baselineY,
    stepWidth: step,
    valueTicks: buildTicks(minValue, maxValue),
    dateLabels,
  };
}

function buildSmoothPath(points: ChartPoint[], yKey: "incomeY" | "expenseY" | "netY") {
  if (points.length === 0) return "";
  if (points.length === 1) return `M${points[0].positionX.toFixed(2)} ${points[0][yKey].toFixed(2)}`;
  const segments = [`M${points[0].positionX.toFixed(2)} ${points[0][yKey].toFixed(2)}`];
  for (let index = 0; index < points.length - 1; index += 1) {
    const previousPoint = points[Math.max(0, index - 1)];
    const currentPoint = points[index];
    const nextPoint = points[index + 1];
    const followingPoint = points[Math.min(points.length - 1, index + 2)];
    const controlPointStartX = currentPoint.positionX + (nextPoint.positionX - previousPoint.positionX) / 6;
    const controlPointStartY = currentPoint[yKey] + (nextPoint[yKey] - previousPoint[yKey]) / 6;
    const controlPointEndX = nextPoint.positionX - (followingPoint.positionX - currentPoint.positionX) / 6;
    const controlPointEndY = nextPoint[yKey] - (followingPoint[yKey] - currentPoint[yKey]) / 6;
    segments.push(`C${controlPointStartX.toFixed(2)} ${controlPointStartY.toFixed(2)}, ${controlPointEndX.toFixed(2)} ${controlPointEndY.toFixed(2)}, ${nextPoint.positionX.toFixed(2)} ${nextPoint[yKey].toFixed(2)}`);
  }
  return segments.join(" ");
}

function buildAreaPath(points: ChartPoint[], yKey: "incomeY" | "expenseY" | "netY", baselineY: number) {
  const linePath = buildSmoothPath(points, yKey);
  if (!linePath || points.length === 0) return "";
  const firstPoint = points[0];
  const lastPoint = points[points.length - 1];
  return `${linePath} L${lastPoint.positionX.toFixed(2)} ${baselineY.toFixed(2)} L${firstPoint.positionX.toFixed(2)} ${baselineY.toFixed(2)} Z`;
}

function scaleValue(value: number, min: number, max: number, bottom: number, height: number) {
  if (max <= min) return bottom;
  return bottom - Math.min(1, Math.max(0, (value - min) / (max - min))) * height;
}

function niceMax(value: number) {
  if (!Number.isFinite(value) || value <= 0) return 1;
  const power = 10 ** Math.floor(Math.log10(value));
  const normalized = value / power;
  const nice = normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
  return nice * power;
}

function niceMin(value: number, max: number) {
  if (!Number.isFinite(value) || value >= 0) return 0;
  const absoluteMax = Math.max(Math.abs(value), max);
  const nice = niceMax(absoluteMax);
  return -nice;
}

function niceDailyMin(value: number, max: number) {
  if (!Number.isFinite(value) || value >= 0) return 0;
  const bounded = Math.max(Math.abs(value), max * 0.28);
  return -niceMax(bounded);
}

function buildTicks(min: number, max: number) {
  const ticks = [min, min + (max - min) * 0.25, min + (max - min) * 0.5, min + (max - min) * 0.75, max];
  return Array.from(new Set(ticks.map((tick) => Math.round(tick))));
}

function compactMoney(value: number) {
  if (Math.abs(value) >= 10000) return `${Math.round(value / 10000)}万`;
  if (Math.abs(value) >= 1000) return `${Math.round(value / 1000)}k`;
  return `${Math.round(value)}`;
}
