#!/bin/bash

set -euo pipefail

show_usage() {
	cat <<-EOF
	Usage: $(basename "$0") -u USERNAME -p PROJECT -l PIPELINE_PATTERN -s SESSION [OPTIONS]
	
	Retrieves log files from supercomputer using rsync.
	
	Required arguments:
	  -u USERNAME          Remote username
	  -p PROJECT           Project name
	  -l PIPELINE_PATTERN  Pipeline pattern (case-insensitive substring match)
	  -s SESSION           Session identifier
	
	Optional arguments:
	  -r REGEX             File regex pattern (can be specified multiple times)
	                       Defaults: 'stdout$' 'stderr$'
	  -d DESTINATION       Local destination directory (default: current directory)
	  -n                   Dry run (show what would be transferred)
	  -v                   Verbose output
	  -h                   Show this help message
	
	Example:
	  $(basename "$0") -u myuser -p my_project -l "analysis" -s session_2024
	  $(basename "$0") -u myuser -p my_project -l "proc" -s sess -r '\.log$' -r '\.err$'
	EOF
}

username=""
project=""
pipeline_pattern=""
session=""
job_directory=""
destination_directory="."
dry_run_flag=""
verbose_flag=""
declare -a file_regexes=()

while getopts "u:p:l:s:j:r:d:nvh" option; do
	case $option in
		u)
			username="$OPTARG"
			;;
		p)
			project="$OPTARG"
			;;
		l)
			pipeline_pattern="$OPTARG"
			;;
		s)
			session="$OPTARG"
			;;
		r)
			file_regexes+=("$OPTARG")
			;;
		d)
			destination_directory="$OPTARG"
			;;
		n)
			dry_run_flag="--dry-run"
			;;
		v)
			verbose_flag="--verbose"
			;;
		h)
			show_usage
			exit 0
			;;
		\?)
			echo "Error: Invalid option -$OPTARG" >&2
			show_usage
			exit 1
			;;
	esac
done

if [[ -z "$username" ]] || [[ -z "$project" ]] || [[ -z "$pipeline_pattern" ]] || [[ -z "$session" ]]; then
	echo "Error: Missing required arguments" >&2
	show_usage
	exit 1
fi

if [[ ${#file_regexes[@]} -eq 0 ]]; then
	file_regexes=("stdout$" "stderr$")
fi

remote_host="${username}@login3.chpc.wustl.edu"
remote_base_path="/ceph/scratch/intradb/build/chpc/build/nrg-svc-hcpi"

find_pipeline_directory() {
	local pattern="$1"
	local base_path="$2"
	
	echo "Searching for pipelines matching pattern: '$pattern'" >&2
	
	local matches
	matches=$(ssh "$remote_host" \
		"find '$base_path' -maxdepth 1 -type d | grep -i '$pattern' 2>/dev/null" \
		2>/dev/null || true)
	
	if [[ -z "$matches" ]]; then
		echo "Error: No pipeline directories found matching pattern '$pattern'" >&2
		return 1
	fi
	
	local match_count
	match_count=$(echo "$matches" | wc -l)
	
	if [[ $match_count -gt 1 ]]; then
		echo "Error: Multiple pipeline directories match pattern '$pattern':" >&2
		echo "$matches" | sed 's/^/  /' >&2
		echo "Please use a more specific pattern" >&2
		return 1
	fi
	
	basename "$matches"
}

find_latest_job_directory() {
	local project_path="$1"
	local session_pattern="$2"
	
	echo "Finding latest job directory for session: $session_pattern" >&2
	
	local all_directories=$(ssh "$remote_host" \
		"ls -d ${project_path}/*${session_pattern}*_CHECK_DATA 2>/dev/null || true" \
		2>/dev/null || true)
	
	all_directories=$(echo "$all_directories" | grep -v '^$' | sort -V)
	
	if [[ -z "$all_directories" ]]; then
		echo "Error: No job directories found for session '$session_pattern'" >&2
		return 1
	fi
	
	local latest_directory
	latest_directory=$(echo "$all_directories" | tail -n 1)
	
	basename "$latest_directory"
}

build_regex_pattern() {
	local pattern="("
	local first=true
	
	for regex in "${file_regexes[@]}"; do
		if [[ "$first" == true ]]; then
			first=false
		else
			pattern="${pattern}|"
		fi
		pattern="${pattern}${regex}"
	done
	
	pattern="${pattern})"
	echo "$pattern"
}

echo "Connecting to $remote_host to search for pipeline..." >&2
pipeline_directory=$(find_pipeline_directory "$pipeline_pattern" "$remote_base_path")

if [[ -z "$pipeline_directory" ]]; then
	exit 1
fi

echo "Found pipeline: $pipeline_directory" >&2

remote_project_path="${remote_base_path}/${pipeline_directory}/${project}"

job_directory=$(find_latest_job_directory "$remote_project_path" "$session")

full_remote_path=$(echo $remote_project_path/$job_directory | sed -r 's/_CHECK_DATA.?$/*/')
echo $full_remote_path

mkdir -p "$destination_directory"

regex_pattern=$(build_regex_pattern)

echo "Finding files matching regex patterns: ${file_regexes[*]}" >&2

file_list=$(ssh "$remote_host" \
	"find $full_remote_path | grep -E '$regex_pattern'" \
	2>/dev/null || true)


if [[ -z "$file_list" ]]; then
	echo "Warning: No files found matching the specified patterns" >&2
	exit 0
fi

echo "Found $(echo "$file_list" | wc -l) matching files" >&2

rsync_options=("-avz" "--progress")

if [[ -n "$dry_run_flag" ]]; then
	rsync_options+=("$dry_run_flag")
	echo "DRY RUN MODE - No files will be transferred" >&2
fi

if [[ -n "$verbose_flag" ]]; then
	rsync_options+=("$verbose_flag")
	echo "Files to transfer:" >&2
	echo "$file_list" | sed 's/^/  /' >&2
fi

echo "Retrieving files from: ${remote_host}:${full_remote_path}" >&2
echo "Destination: $destination_directory" >&2
echo "----------------------------------------" >&2

while IFS= read -r file_path; do
	filename=$(basename "$file_path")
	rsync "${rsync_options[@]}" "${remote_host}:${file_path}" "$destination_directory/${filename}"
done <<< "$file_list"

echo "----------------------------------------" >&2
echo "Transfer complete" >&2

