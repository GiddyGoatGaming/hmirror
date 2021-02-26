#!/bin/sh

# Author:     Héctor Molinero Fernández <hector@molinero.dev>
# License:    MIT, https://opensource.org/licenses/MIT
# Repository: https://github.com/hectorm/hmirror

set -eu
export LC_ALL='C'

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${0:?}")" && pwd -P)"

printInfo() { [ -t 1 ] && printf -- '\033[0m[\033[1;32mINFO\033[0m] %s\n' "${@}" || printf -- '[INFO] %s\n' "${@}"; }
printWarn() { [ -t 1 ] && printf -- '\033[0m[\033[1;33mWARN\033[0m] %s\n' "${@}" >&2 || printf -- '[WARN] %s\n' "${@}" >&2; }
printError() { [ -t 1 ] && printf -- '\033[0m[\033[1;31mERROR\033[0m] %s\n' "${@}" >&2 || printf -- '[ERROR] %s\n' "${@}" >&2; }
printList() { [ -t 1 ] && printf -- '\033[0m \033[1;36m*\033[0m %s\n' "${@}" || printf -- ' * %s\n' "${@}" >&2; }

fetchUrl() { curl -fsSL -A 'Mozilla/5.0 (X11; Linux x86_64; rv:78.0) Gecko/20100101 Firefox/78.0' -- "${1:?}"; }

removeCR() { tr -d '\r'; }
toLowercase() { sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/'; }

hostsToDomains() {
	leadingScript='s/^[[:blank:]]*//'
	trailingScript='s/[[:blank:]]*\(#.*\)\{0,1\}$//'
	ipv4Script='s/^\(0\)\{0,1\}\(127\)\{0,1\}\(\.[0-9]\{1,3\}\)\{3\}[[:blank:]]\{1,\}//'
	ipv6Script='s/^\(0\{0,4\}:\)\{2,7\}0\{0,3\}[01]\{0,1\}[[:blank:]]\{1,\}//'
	domainRegex='^\([0-9a-z_-]\{1,63\}\.\)\{1,\}[a-z][0-9a-z_-]\{1,62\}$'

	removeCR | toLowercase \
		| sed -e "${leadingScript:?};${ipv4Script:?};${ipv6Script:?};${trailingScript:?}" \
		| { grep -e "${domainRegex:?}" ||:; } | sort | uniq
}

adblockToDomains() {
	domainRegex='\([0-9a-z_-]\{1,63\}\.\)\{1,\}[a-z][0-9a-z_-]\{1,62\}'
	adblockScript='s/^||\('"${domainRegex:?}"'\)\^$/\1/p' # 's/^||\([0-9a-z._-]\{1,\}\).\{0,1\}$/\1/'
	adblockExceptionScript='s/^@@||\('"${domainRegex:?}"'\).*/\1/p'

	contentFile="$(mktemp)"
	removeCR | toLowercase > "${contentFile:?}"

	domainsPipe="$(mktemp -u)"; mkfifo -m 600 "${domainsPipe:?}"
	sed -ne "${adblockScript:?}" -- "${contentFile:?}" | sort | uniq > "${domainsPipe:?}" &

	exceptionsPipe="$(mktemp -u)"; mkfifo -m 600 "${exceptionsPipe:?}"
	sed -ne "${adblockExceptionScript:?}" -- "${contentFile:?}" | sort | uniq > "${exceptionsPipe:?}" &

	comm -23 -- "${domainsPipe:?}" "${exceptionsPipe:?}"
	rm -f -- "${contentFile:?}" "${domainsPipe:?}" "${exceptionsPipe:?}"
}

main() {
	sources="$(jq -r '.sources|map(select(.enabled))' -- "${SCRIPT_DIR:?}/sources.json")"
	sourcesTotal="$(jq -nr --argjson d "${sources:?}" '$d|length-1')"

	tmpWorkDir="$(mktemp -d)"
	# shellcheck disable=SC2154
	trap 'ret="$?"; rm -rf -- "${tmpWorkDir:?}"; trap - EXIT; exit "${ret:?}"' EXIT TERM INT HUP

	printInfo 'Downloading lists...'

	sourcesIndex='0'
	while [ "${sourcesIndex:?}" -le "${sourcesTotal:?}" ]; do
		source="$(jq -nr --argjson d "${sources:?}" --arg i "${sourcesIndex:?}" '$d[$i|tonumber]')"
		name="$(jq -nr --argjson d "${source:?}" '$d.name')"
		format="$(jq -nr --argjson d "${source:?}" '$d.format')"
		url="$(jq -nr --argjson d "${source:?}" '$d.url')"

		printList "${url:?}"

		tmpFile="${tmpWorkDir:?}/${name:?}.txt"
		outFile="${SCRIPT_DIR:?}/data/${name:?}/list.txt"

		if fetchUrl "${url:?}" > "${tmpFile:?}"; then
			mkdir -p "${outFile%/*}"

			if [ "${format:?}" = 'hosts' ]; then
				hostsToDomains < "${tmpFile:?}" > "${outFile:?}"
			elif [ "${format:?}" = 'adblock' ]; then
				adblockToDomains < "${tmpFile:?}" > "${outFile:?}"
			fi

			checksum="$(sha256sum "${outFile:?}" | cut -c 1-64)"
			printf '%s  %s\n' "${checksum:?}" "${outFile##*/}" > "${outFile:?}.sha256"
		else
			printError 'Download failed'
		fi

		sourcesIndex="$((sourcesIndex+1))"
	done
}

main "${@-}"
