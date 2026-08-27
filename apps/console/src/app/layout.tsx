import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "BlakTail console",
  description:
    "Manage BlakTail devices, join keys, and access policy for your organisation.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en-AU">
      <body>{children}</body>
    </html>
  );
}
