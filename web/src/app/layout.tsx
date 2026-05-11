import type { Metadata, Viewport } from "next";
import { PwaRegister } from "@/components/PwaRegister";
import "./globals.css";

export const metadata: Metadata = {
  title: "我的账本",
  description: "Beancount ledger web app",
  manifest: "/manifest.webmanifest",
  applicationName: "我的账本",
  appleWebApp: {
    capable: true,
    statusBarStyle: "black-translucent",
    title: "我的账本",
  },
  icons: {
    icon: "/icons/icon-192.svg",
    apple: "/icons/icon-192.svg",
  },
};

export const viewport: Viewport = {
  themeColor: "#1B365D",
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="zh-CN"><body><PwaRegister />{children}</body></html>;
}
