"use client";

import type { AnchorHTMLAttributes, ReactNode } from "react";
import { navigate } from "@/lib/browserRouter";

type ClientNavLinkProps = AnchorHTMLAttributes<HTMLAnchorElement> & {
  href: string;
  children: ReactNode;
};

export function ClientNavLink({ href, children, ...props }: ClientNavLinkProps) {
  return <a href={href} {...props} onClick={(event) => {
    props.onClick?.(event);
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    navigate(href);
  }}>{children}</a>;
}
