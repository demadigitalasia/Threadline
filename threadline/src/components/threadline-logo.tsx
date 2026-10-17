import Image from "next/image";

type ThreadlineLogoProps = {
  surface?: "tile" | "transparent";
  compact?: boolean;
  size?: "regular" | "small";
  className?: string;
};

export function ThreadlineLogo({
  surface = "tile",
  compact = false,
  size = "regular",
  className = "",
}: ThreadlineLogoProps) {
  const markSize = compact ? "h-10 w-10" : size === "small" ? "h-9 w-9" : "h-10 w-10";
  const wordSize = size === "small" ? "text-base" : "text-lg";

  return (
    <div
      role={compact ? "img" : undefined}
      aria-label={compact ? "Threadline" : undefined}
      className={`inline-flex max-w-full items-center gap-2 ${surface === "tile" ? "rounded-xl bg-indigo-950 px-2.5 py-1.5" : ""} ${className}`}
    >
      <Image
        src="/threadline-mark-v2.png"
        alt=""
        aria-hidden
        width={1254}
        height={1254}
        sizes={compact ? "40px" : size === "small" ? "36px" : "40px"}
        className={`${markSize} shrink-0 object-contain`}
      />
      {!compact && <span className={`truncate ${wordSize} font-extrabold tracking-tight text-white`}>Threadline</span>}
    </div>
  );
}
