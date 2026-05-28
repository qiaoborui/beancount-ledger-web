import type { Config } from "tailwindcss";

const color = (name: string) => `rgb(var(--color-${name}) / <alpha-value>)`;

const config: Config = {
  darkMode: ["selector", 'html[data-theme="dark"]'],
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        background: color("background"),
        foreground: color("foreground"),
        primary: color("primary"),
        "primary-foreground": color("primary-foreground"),
        secondary: color("secondary"),
        "secondary-foreground": color("secondary-foreground"),
        muted: color("muted"),
        "muted-foreground": color("muted-foreground"),
        accent: color("accent"),
        "accent-foreground": color("accent-foreground"),
        destructive: color("destructive"),
        border: color("border"),
        input: color("input"),
        ring: color("ring"),
        brand: color("brand"),
        brandLight: color("brand-light"),
        ink: color("ink"),
        warm: color("warm"),
        olive: color("olive"),
        stone: color("stone"),
        paper: color("paper"),
        panel: color("panel"),
        sand: color("sand"),
        line: color("line"),
        lineSoft: color("line-soft"),
        tag: color("tag"),
        income: color("income"),
        expense: color("expense"),
        gold: color("gold"),
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
