// What the account row is doing: nothing, asking before a switch or sign-in, or doing it.
export type Action = 'use' | 'signin'
export type Step = { kind: 'idle' } | { kind: 'confirm'; to: string; action: Action } | { kind: 'switching'; to: string; action: Action }

declare module 'claude-code' {
  interface PluginState {
    // shown: true after /account opens the row, false after it's closed, null until either
    // (the row then shows only while usage is above 95%).
    'desktop-account-switcher': { step: Step; redraw: number; shown: boolean | null }
  }
}
