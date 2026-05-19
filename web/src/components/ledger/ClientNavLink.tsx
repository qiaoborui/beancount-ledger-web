"use client";

import Link from "next/link";
import type { AnchorHTMLAttributes, ReactNode } from "react";

type ClientNavLinkProps = AnchorHTMLAttributes<HTMLAnchorElement> & {
  href: string;
  children: ReactNode;
};

export function ClientNavLink({ href, children, ...props }: ClientNavLinkProps) {
  return <Link href={href} prefetch {...props}>{children}</Link>;
}
