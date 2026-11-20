module github.com/kernelguru/shellwave/poc/nbkit

go 1.26.0

require github.com/netbirdio/netbird v0.83.1

// Übernommen aus NetBirds go.mod: replace-Direktiven gelten nicht für abhängige Module.
replace github.com/cloudflare/circl => codeberg.org/cunicu/circl v0.0.0-20230801113412-fec58fc7b5f6

replace github.com/mailru/easyjson => github.com/netbirdio/easyjson v0.9.0

replace github.com/wailsapp/wails/v3 => github.com/netbirdio/wails/v3 v3.0.0-beta.3.0.20261028091752-cfa103160796
