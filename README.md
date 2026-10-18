Simple tool to manage offline files split across drives (refered further as storage
roots, because it may be a network/cloud storage). 

Features:
- list of remote drives (roots)
    - add, remove
- list of files
    - syncronized on request
- hash sums of each file, and directory (sha256)
- list duplicates
    - list duplicates only within one drive
- list unique

The app must answer the following user's questions:
- what roots there are?
- what files and directories (full path) live on a root, their size, modification date?
- what duplicate files are within the root?
- what duplicate files are across all roots?
- what are unique files across all roots?
- what are unique files in a root?

Implementation:
- D (ldc2)
- sqlite3

Output formats:
- coloured console output
- CSV
