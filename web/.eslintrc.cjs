/* Phase 8 frontend foundation -- lint config. */
module.exports = {
  root: true,
  env: { browser: true, es2022: true },
  parser: "@typescript-eslint/parser",
  parserOptions: { ecmaVersion: "latest", sourceType: "module" },
  plugins: ["@typescript-eslint", "react-hooks", "react-refresh"],
  extends: [
    "eslint:recommended",
    "plugin:@typescript-eslint/recommended",
  ],
  ignorePatterns: ["dist", "coverage", "node_modules", "playwright-report", "test-results"],
  rules: {
    "react-hooks/rules-of-hooks": "error",
    "react-hooks/exhaustive-deps": "warn",
    // Co-locating a context Provider with its `useX` consumer hook in one
    // file is the intended pattern here; HMR granularity is not a concern for
    // the foundation shell, so this dev-only rule is disabled rather than
    // fragmenting the modules.
    "react-refresh/only-export-components": "off",
    "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    "@typescript-eslint/consistent-type-imports": "error",
    "no-console": ["warn", { allow: ["warn", "error"] }],
  },
  overrides: [
    {
      files: ["**/*.{test,spec}.{ts,tsx}", "vitest.setup.ts", "src/test-utils.tsx"],
      env: { node: true },
      rules: { "@typescript-eslint/no-non-null-assertion": "off" },
    },
    {
      files: ["*.config.ts", "playwright.config.ts", "*.cjs"],
      env: { node: true },
    },
  ],
};
