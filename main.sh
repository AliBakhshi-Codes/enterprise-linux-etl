#!/bin/bash
# ==============================================================================
# ETL Pipeline Engine
# Description: Automated ETL pipeline that transfers, cleans, transforms,
#              and loads transaction data into MariaDB using core Linux
#              utilities (awk, sed, tr, sort, cut).
# Usage: ./etl.sh remote-server remote-userid remote-file mysql-user-id mysql-database
# ==============================================================================

# ------------------------------------------------------------------------------
# 1) ERROR HANDLING & GLOBAL SETTINGS
# ------------------------------------------------------------------------------
set -o errexit    # exit if a command fails
set -o pipefail   # pipeline fails on first non-zero exit

# Track whether the script completed successfully (used in cleanup)
SUCCESS=0

# Author name for reports (uses system username)
REPORT_AUTHOR="$(whoami)"

# ------------------------------------------------------------------------------
# 2) USAGE STATEMENT
# ------------------------------------------------------------------------------
if [[ $# -lt 5 ]]; then
    echo "Usage: $0 remote-server remote-userid remote-file mysql-user-id mysql-database"
    echo ""
    echo "Parameters:"
    echo "  remote-server   : Server name or IP address"
    echo "  remote-userid   : SSH username for the remote server"
    echo "  remote-file     : Full path to the remote .csv.bz2 file"
    echo "  mysql-user-id   : MariaDB/MySQL username"
    echo "  mysql-database  : Target database name"
    echo ""
    echo "Example:"
    echo "  $0 40.69.135.45 student /home/shared/MOCK_MIX_v2.1.csv.bz2 dbuser mydb"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3) ASSIGN CLI PARAMETERS
# ------------------------------------------------------------------------------
REMOTE_SERVER="$1"
REMOTE_USER="$2"
REMOTE_FILE="$3"
DB_USER="$4"
DB_NAME="$5"

# Derived file names
LOCAL_ARCHIVE="transaction.bz2"

# Intermediate temp files (cleaned up at the end)
TEMP_FILES=("transaction_noheader" "transaction_lowercase" "transaction_gender"
            "transaction_filtered" "transaction_sorted" "summary_unsorted"
            "txn_counts_tmp" "purchase_summary_tmp" "sort_swp")

# ------------------------------------------------------------------------------
# 4) CLEANUP FUNCTION
# ------------------------------------------------------------------------------
# Project requirement: intermediate files removed on success, kept on error.
cleanup() {
    if [[ "${SUCCESS}" -eq 1 ]]; then
        echo "Cleaning up intermediate working files..."
        for f in "${TEMP_FILES[@]}"; do
            rm -f "./${f}"
        done
        rm -f "./${LOCAL_ARCHIVE}"
        rm -f "./transaction"       # raw unzipped file before rename
        echo "Cleanup complete."
    else
        echo "Script exited with an error. Intermediate files are preserved for debugging."
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 5) VALIDATE SOURCE FILE PARAMETER
# ------------------------------------------------------------------------------
# Basic check: remote file path should not be empty (already guaranteed by $# check)
if [[ -z "${REMOTE_FILE}" ]]; then
    echo "Error: Remote file path is empty."
    exit 1
fi

# ==============================================================================
# STEP 1: Transfer the source file using scp
# ==============================================================================
echo "Step 1) Transferring source file from ${REMOTE_SERVER}..."
if ! scp "${REMOTE_USER}@${REMOTE_SERVER}:${REMOTE_FILE}" "./${LOCAL_ARCHIVE}"; then
    echo "Error: SCP transfer failed. Check server address, credentials, and file path."
    exit 1
fi
echo "Step 1) File transfer -- complete"

# ==============================================================================
# STEP 2: Unzip the transaction file
# ==============================================================================
echo "Step 2) Decompressing the transaction file..."
if ! bunzip2 -f "./${LOCAL_ARCHIVE}"; then
    echo "Error: Failed to decompress ${LOCAL_ARCHIVE}."
    exit 1
fi
# bunzip2 removes the .bz2 and leaves "transaction" (no extension)
echo "Step 2) Decompression -- complete"

# ==============================================================================
# STEP 3: Remove the header record from the transaction file
# ==============================================================================
echo "Step 3) Removing header record..."
# Save the header for later re-insertion
head -1 ./transaction > ./transaction_header
tail -n +2 ./transaction > ./transaction_noheader
echo "Step 3) Header removal -- complete"

# ==============================================================================
# STEP 4: Convert all text to lowercase
# ==============================================================================
echo "Step 4) Converting all text to lowercase..."
tr '[:upper:]' '[:lower:]' < ./transaction_noheader > ./transaction_lowercase
echo "Step 4) Lowercase conversion -- complete"

# ==============================================================================
# STEP 5: Standardize the gender field
# ==============================================================================
# Possible values after lowercase: "f", "m", "female", "male", "1", "0", "", "u", "x", etc.
# Mapping: 1->f, female->f, f->f, 0->m, male->m, m->m, everything else->u
echo "Step 5) Standardizing gender field values..."
awk -F',' -v OFS=',' '{
    if ($5 == "1" || $5 == "female" || $5 == "f") { $5 = "f" }
    else if ($5 == "0" || $5 == "male" || $5 == "m") { $5 = "m" }
    else { $5 = "u" }
    print $0
}' ./transaction_lowercase > ./transaction_gender
echo "Step 5) Gender standardization -- complete"

# ==============================================================================
# STEP 6: Filter records with invalid/missing state field
# ==============================================================================
# Records with empty state or "na" (already lowercase) go to exceptions.csv
echo "Step 6) Filtering records with invalid or missing state..."
awk -F',' -v OFS=',' '{
    if ($12 == "" || $12 == "na") {
        print $0 >> "exceptions.csv"
    } else {
        print $0
    }
}' ./transaction_gender > ./transaction_filtered
echo "Step 6) State filtering -- complete"

# ==============================================================================
# STEP 7: Remove the $ sign from purchase amount field
# ==============================================================================
echo "Step 7) Removing '$' from purchase amount field..."
sed -i 's/\$//g' ./transaction_filtered
echo "Step 7) Currency symbol removal -- complete"

# ==============================================================================
# STEP 8: Sort by customerID and produce transaction.csv
# ==============================================================================
echo "Step 8) Sorting transaction file by customerID..."
sort -t',' -k1,1 ./transaction_filtered > ./transaction_sorted

# Re-attach the original header (lowercase version)
echo "customer_id,first_name,last_name,email,gender,purchase_amount,credit_card,transaction_id,transaction_date,street,city,state,zip,phone" \
    | cat - ./transaction_sorted > ./transaction.csv
echo "Step 8) Sorted transaction.csv generated -- complete"

# ==============================================================================
# STEP 9: Generate summary.csv
# ==============================================================================
# Accumulate total purchase per customerID.
# Output fields: customerID, state, zip, lastname, firstname, total_purchase_amount
# Sort: state asc, zip desc (numeric), lastname asc, firstname asc
echo "Step 9) Generating summary file..."
awk -F',' -v OFS=',' '{
    # Skip header if present
    if (NR == 1 && $1 == "customer_id") next
    state[$1]  = $12
    zip[$1]    = $13
    lname[$1]  = $3
    fname[$1]  = $2
    total[$1] += $6
} END {
    for (id in state) {
        printf "%s,%s,%s,%s,%s,%.2f\n", id, state[id], zip[id], lname[id], fname[id], total[id]
    }
}' ./transaction.csv > ./summary_unsorted

# Priority sort: state asc, zip desc numeric, lastname asc, firstname asc
sort -t',' -k2,2 -k3,3nr -k4,4 -k5,5 ./summary_unsorted > ./summary_body

# Add header and finalize
echo "customer_id,state,zip,last_name,first_name,total_purchase_amount" \
    | cat - ./summary_body > ./summary.csv
rm -f ./summary_body
echo "Step 9) summary.csv generated -- complete"

# ==============================================================================
# STEP 10a: Transaction Count Report (transaction.rpt)
# ==============================================================================
# Count transactions per state (uppercase), sort by count desc then state asc
echo "Step 10a) Generating Transaction Count Report..."
awk -F',' 'NR > 1 {
    s = toupper($12)
    count[s]++
} END {
    for (s in count) print s "," count[s]
}' ./transaction.csv | sort -t',' -k2,2nr -k1,1 > ./txn_counts_tmp

{
    printf "Report by: %s\n" "${REPORT_AUTHOR}"
    printf "Transaction Count Report\n"
    printf "%-10s %s\n" "State" "Transaction Count"
    awk -F',' '{ printf "%-10s %d\n", $1, $2 }' ./txn_counts_tmp
} > ./transaction.rpt
echo "Step 10a) transaction.rpt generated -- complete"

# ==============================================================================
# STEP 10b: Purchase Summary Report (purchase.rpt)
# ==============================================================================
# Total purchases by state + gender (uppercase).
# Sort: total desc, state asc, gender asc
echo "Step 10b) Generating Purchase Summary Report..."
awk -F',' 'NR > 1 {
    key = toupper($12) "," toupper($5)
    sum[key] += $6
} END {
    for (k in sum) printf "%s,%.2f\n", k, sum[k]
}' ./transaction.csv | sort -t',' -k3,3nr -k1,1 -k2,2 > ./purchase_summary_tmp

{
    printf "Report by: %s\n" "${REPORT_AUTHOR}"
    printf "Purchase Summary Report\n"
    printf "%-10s %-10s %s\n" "State" "Gender" "Report"
    awk -F',' '{ printf "%-10s %-10s %.2f\n", $1, $2, $3 }' ./purchase_summary_tmp
} > ./purchase.rpt
echo "Step 10b) purchase.rpt generated -- complete"

# ==============================================================================
# STEP 11: Load files into MariaDB
# ==============================================================================
echo "Step 11) Loading data into MariaDB..."

# Prompt for password (hidden input)
read -s -p "Please enter the password for MySQL database: " DB_PASS
echo ""

# Create tables (drop if they exist for a clean load)
mysql -u "${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" <<EOF
DROP TABLE IF EXISTS transaction;
CREATE TABLE transaction (
    customer_id VARCHAR(100),
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    email VARCHAR(100),
    gender VARCHAR(10),
    purchase_amount DECIMAL(13,2),
    credit_card VARCHAR(100),
    transaction_id VARCHAR(100),
    transaction_date DATE,
    street VARCHAR(150),
    city VARCHAR(100),
    state VARCHAR(50),
    zip VARCHAR(50),
    phone VARCHAR(50)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

DROP TABLE IF EXISTS summary;
CREATE TABLE summary (
    customer_id VARCHAR(100),
    state VARCHAR(50),
    zip VARCHAR(50),
    last_name VARCHAR(100),
    first_name VARCHAR(100),
    total_purchase_amount DECIMAL(13,2)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;
EOF

# Load transaction.csv into the transaction table
echo "Loading transaction.csv..."
mysqlimport --local --ignore-lines=1 \
    --fields-terminated-by=',' \
    --lines-terminated-by='\n' \
    -u "${DB_USER}" -p"${DB_PASS}" \
    "${DB_NAME}" "$(pwd)/transaction.csv"

# Load summary.csv into the summary table
echo "Loading summary.csv..."
mysqlimport --local --ignore-lines=1 \
    --fields-terminated-by=',' \
    --lines-terminated-by='\n' \
    -u "${DB_USER}" -p"${DB_PASS}" \
    "${DB_NAME}" "$(pwd)/summary.csv"

echo "Step 11) Database loading -- complete"

# ==============================================================================
# STEP 12: Mark success so cleanup removes only intermediate files
# ==============================================================================
SUCCESS=1
echo ""
echo "================================================================="
echo "ETL process completed successfully!"
echo "Final output files:"
echo "  - transaction.csv"
echo "  - exceptions.csv"
echo "  - summary.csv"
echo "  - transaction.rpt"
echo "  - purchase.rpt"
echo "================================================================="