import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        brand: "#1B365D",
        brandLight: "#2D5A8A",
        ink: "#141413",
        warm: "#3d3d3a",
        olive: "#504e49",
        stone: "#6b6a64",
        paper: "#f5f4ed",
        panel: "#faf9f5",
        sand: "#e8e6dc",
        line: "#e8e6dc",
        lineSoft: "#e5e3d8",
        tag: "#EEF2F7",
        income: "#4a6b55",
        expense: "#8e4a3d",
        gold: "#8a6f2f",
      },
      fontFamily: {
        sans: ["var(--font-sans)", "ui-sans-serif", "system-ui"],
        serif: ["var(--font-serif)", "ui-serif", "Georgia"],
      },
    },
  },
  plugins: [],
};

export default config;
