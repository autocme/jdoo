#!/bin/bash
# =============================================================================
# derive-restart-after.sh — compute RESTART_AFTER from ODOO_ADDONS_PATHS
# =============================================================================
# The j_jdoo_cicd `restart-after` container label lists the repos whose push should
# restart this container to load new code. To avoid maintaining it separately
# from the addons_path, derive it from ODOO_ADDONS_PATHS: every path of the
# form /repos/<branch>/<repo> becomes an entry <repo>/<branch>.
#
# Precedence:
#   1. RESTART_AFTER already set (env/.env)  → kept as-is (explicit override)
#   2. ODOO_ADDONS_PATHS set                 → derived from its /repos/* entries
#   3. neither                               → empty (compose falls back to
#                                              oa/${ODOO_VERSION})
#
# Prints the computed value to stdout (empty string if nothing to derive).
# Usage: RESTART_AFTER=$(ODOO_ADDONS_PATHS=... bash derive-restart-after.sh)
# =============================================================================

# Explicit override wins.
if [ -n "${RESTART_AFTER:-}" ]; then
    printf '%s' "$RESTART_AFTER"
    exit 0
fi

paths="${ODOO_ADDONS_PATHS:-}"
[ -z "$paths" ] && exit 0

out=""
seen=""
IFS=',' read -ra _arr <<< "$paths"
for p in "${_arr[@]}"; do
    # trim surrounding whitespace
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    case "$p" in
        /repos/*/*)
            rest="${p#/repos/}"     # <branch>/<repo>[/...]
            branch="${rest%%/*}"    # <branch>
            repo="${rest#*/}"       # <repo>[/...]
            repo="${repo%%/*}"      # first segment only
            [ -z "$branch" ] || [ -z "$repo" ] && continue
            entry="${repo}/${branch}"
            # de-dupe
            case ",$seen," in *",$entry,"*) continue ;; esac
            seen="${seen:+$seen,}$entry"
            out="${out:+$out,}$entry"
            ;;
    esac
done

printf '%s' "$out"
