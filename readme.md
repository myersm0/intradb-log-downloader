Designed to allow easy identification and retrieval of logfiles from IntraDb pipeline runs on our CHPC system.

## Usage
Clone the project, cd into it, and then try something like:
```
./download.sh -p $project_id -l $pipeline_substring -s $session_id -u $user_id -r ".stderr" -r ".stdout" -r "error_"
```

Replace variables in the call as appropriate for your case. You can specify an arbitrary number of file regexes that you want to match, via the `-r` repeatable argument. Such files will be searched in the _latest_ processing directory(ies) for the specified session, project, and pipeline combination (the pipeline argument `-l` need only match a uniquely identifying substring of the full pipeline name, case insensitively).
