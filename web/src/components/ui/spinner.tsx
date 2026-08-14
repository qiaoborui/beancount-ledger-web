import type { ComponentProps, CSSProperties } from "react"

import { cn } from "@/lib/utils"

const spiralSteps = [
  0, 1, 2, 3, 4,
  15, 16, 17, 18, 5,
  14, 23, 24, 19, 6,
  13, 22, 21, 20, 7,
  12, 11, 10, 9, 8,
] as const

const sizeClasses = {
  sm: "dot-matrix-loader--sm",
  md: "dot-matrix-loader--md",
  lg: "dot-matrix-loader--lg",
} as const

type DotMatrixLoaderProps = Omit<ComponentProps<"span">, "children"> & {
  size?: keyof typeof sizeClasses
}

function DotMatrixLoader({
  "aria-hidden": ariaHidden,
  "aria-label": ariaLabel = "Loading",
  className,
  role = "status",
  size = "md",
  ...props
}: DotMatrixLoaderProps) {
  const hidden = ariaHidden === true || ariaHidden === "true"

  return (
    <span
      aria-hidden={ariaHidden}
      aria-label={hidden ? undefined : ariaLabel}
      className={cn("dot-matrix-loader", sizeClasses[size], className)}
      data-slot="dot-matrix-loader"
      role={hidden ? undefined : role}
      {...props}
    >
      {spiralSteps.map((step, index) => (
        <span
          aria-hidden="true"
          className="dot-matrix-loader__dot"
          key={index}
          style={{ "--dot-delay": `-${step * 56}ms` } as CSSProperties}
        />
      ))}
    </span>
  )
}

const Spinner = DotMatrixLoader

export { DotMatrixLoader, Spinner }
export type { DotMatrixLoaderProps }
