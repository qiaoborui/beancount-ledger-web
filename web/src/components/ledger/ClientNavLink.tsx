"use client";

import type { AnchorHTMLAttributes, MouseEvent, ReactNode } from "react";

type ClientNavLinkProps = AnchorHTMLAttributes<HTMLAnchorElement> & {
  href: string;
  children: ReactNode;
};

export function ClientNavLink({ href, onClick, children, ...props }: ClientNavLinkProps) {
  function handleClick(event: MouseEvent<HTMLAnchorElement>) {
    onClick?.(event);
    if (event.defaultPrevented) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;

    const target = event.currentTarget.target;
    if (target && target !== "_self") return;

    const nextUrl = new URL(href, window.location.href);
    if (nextUrl.origin !== window.location.origin) return;
    if (nextUrl.pathname === window.location.pathname && nextUrl.search === window.location.search && nextUrl.hash === window.location.hash) return;

    event.preventDefault();
    window.history.pushState(null, "", `${nextUrl.pathname}${nextUrl.search}${nextUrl.hash}`);
  }

  return <a href={href} onClick={handleClick} {...props}>{children}</a>;
}
