"use client";

import type { AnchorHTMLAttributes, FocusEvent, PointerEvent, ReactNode, TouchEvent } from "react";
import { navigate } from "@/lib/browserRouter";
import { preloadLedgerRoute } from "./routePreload";

type ClientNavLinkProps = AnchorHTMLAttributes<HTMLAnchorElement> & {
  href: string;
  children: ReactNode;
  prefetch?: boolean;
};

export function ClientNavLink({ href, children, prefetch = true, onClick, onPointerEnter, onFocus, onTouchStart, ...props }: ClientNavLinkProps) {
  const prefetchRoute = () => {
    if (prefetch) preloadLedgerRoute(href);
  };
  return <a href={href} {...props} onPointerEnter={(event: PointerEvent<HTMLAnchorElement>) => {
    onPointerEnter?.(event);
    prefetchRoute();
  }} onFocus={(event: FocusEvent<HTMLAnchorElement>) => {
    onFocus?.(event);
    prefetchRoute();
  }} onTouchStart={(event: TouchEvent<HTMLAnchorElement>) => {
    onTouchStart?.(event);
    prefetchRoute();
  }} onClick={(event) => {
    onClick?.(event);
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    prefetchRoute();
    navigate(href);
  }}>{children}</a>;
}
