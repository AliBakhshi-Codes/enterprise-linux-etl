# Linux ETL Data Pipeline

This repository contains a comprehensive Bash script that automates an Extract, Transform, and Load (ETL) pipeline. The script securely transfers raw transaction data from a remote server, processes it using standard Linux text utilities, and loads the structured output into a MariaDB database.

## Project Workflow

The pipeline runs entirely in the Linux terminal and is broken down into the following stages:

*   **Extraction:** Securely downloads a compressed data archive from a remote node using `scp` and extracts it locally via `bunzip2`.
*   **Transformation:** Cleans and formats the raw CSV data. It removes headers, converts all text to lowercase, standardizes categorical fields (like gender), and strips currency symbols using core utilities such as `awk`, `sed`, and `tr`.
*   **Data Integrity:** Identifies records with missing or invalid fields and isolates them into a separate exceptions file for further review, ensuring only clean data moves forward.
*   **Reporting:** Aggregates the cleaned data to generate specific business reports (e.g., transaction counts and purchase summaries) using multi-level `sort` and `awk` operations.
*   **Database Ingestion:** Automatically builds the required database tables and performs a high-speed bulk data load into MariaDB/MySQL using `mysqlimport`.

## Key Technical Features

*   **Strict Error Handling:** Implements `set -o errexit` and `set -o pipefail` to ensure the script stops immediately if any critical command in the pipeline fails.
*   **Automated Cleanup:** Uses POSIX `trap` signals to guarantee that all intermediate temporary files are deleted when the script finishes or if it is unexpectedly interrupted.
*   **Secure Authentication:** Database credentials are not hardcoded. The script securely prompts the user for the database password at runtime to prevent security leaks in the shell history.

## Usage

To run the pipeline, execute the script with the required network and database parameters:

```bash
./etl.sh <remote-server> <remote-userid> <remote-file> <mysql-user-id> <mysql-database>
