#!/bin/bash


# Usage statement
if [ $# -eq 0 ]
  then
    echo "Usage: etl.sh remote-server remote-userid remote-file mysql-user-id mysql-database"
    exit 1
fi
echo "$2@$1:$3"
# Remote file transfer
echo "Transferring the source file using scp command..."
scp $2@$1:$3 ./transaction.bz2
cp ./transaction.bz2 MOCK_MIX_v2.1.csv.bz2

# Unzip the transaction file
echo "Unzipping the transaction file..."
bunzip2 ./transaction.bz2

# Remove header record from the transaction file
echo "Removing header record from the transaction file..."
tail -n +2 ./transaction > ./transaction_noheader

# Convert all text in the transaction file to lowercase
echo "Converting all text in the transaction file to lowercase..."
tr '[:upper:]' '[:lower:]' < ./transaction_noheader > ./transaction_lowercase

# Convert gender field values
echo "Converting gender field values to standard format..."
#awk -F"," '{if($5=="1"){$5="f"} else if($5=="0"){$5="m"} else if($5=="male"){$5="m"} else if($5=="female"){$5="f"} else if ($5=="NA"){$5="u"} else {$5="u"}}1' OFS=',' ./transaction_lowercase > ./transaction_gender

awk -F"," '{if($5=="1"){$5="f"} else if($5=="0"){$5="m"} else if($5=="male"){$5="m"} else if($5=="female"){$5="f"} else if ($5==""){$5="u"} else {$5="u"}}1' OFS=',' ./transaction_lowercase >  ./transaction_gender

# Filter records with invalid or missing state field
echo "Filtering records with invalid or missing state field..."
awk -F"," '{if($12=="" || $12=="NA" || $12=="na" ){print $0 > "exceptions.csv"} else {print $0}}' ./transaction_gender > ./transaction_filtered

# Remove $ sign from purchase amount field
echo "Removing $ sign from purchase amount field..."
sed  -i 's/[$]//g' ./transaction_filtered 
#sed -i  's/...$//g' ./transaction_filtered

# Sort transaction file by customerID
echo "Sorting transaction file by customerID..."
sort -t, -k1n ./transaction_filtered > ./transaction_sorted

# add heade record to create csv file 
head -n 1 transaction | cat - transaction_sorted > ./transaction.csv

# sorted cvs file based on Zip code decending order
cut -d , -f 1-3,6,12-13 transaction.csv  > ./sorted_transaction.csv

# Sort csv file based on 
tail -n +2 sorted_transaction.csv|sort -t"," -k5r > sort_swp
head -n 1  sorted_transaction.csv | cat - sort_swp > summary.csv
rm sort_swp

# Generate purchase report
echo "Generating purchase report..."
cut -d , -f 8,12 transaction.csv | tail -n +2| awk -F"," '{print $1,$2}'|sort -k1 > sort_swp
name=$(whoami)
awk 'BEGIN  { print "State                          Transaction ID"}{ printf "%-20s  %21s\n ", $2, $1}' sort_swp  |sed -e ' 1i\   Reported by '"$name"'\n\n  Transaction ID Report\n\n' > ./Transaction-rpt
rm sort_swp

# Generate purchase report
echo "Generating purchase report..."
cut -d , -f 12,5,6 transaction.csv | tail -n +2| awk -F"," '{print $2,$1,$3}'|sort -k1 |sort -nr > sort_swp
awk 'BEGIN  { print "State      Gender      Report"}{ printf "%-10s %3s\t %11s\n ", $3, $2, $1 }' sort_swp  |sed -e ' 1i\   Reported by '"$name"'\n\n  Purchase Count Report\n' > ./purchase-rpt
rm sort_swp
rm sorted_transaction.csv transaction_filtered transaction_lowercase transaction_noheader transaction_gender transaction_sorted transaction

# Load files into MySQL
echo "Loading files into MySQL..."
read -s -p "Please enter the password for MySQL database: "  mysql_password
# define database connectivity
_db=$5
_db_user=$4
_cvs_dir=$PWD/DB

#echo "++++++++++++++++++++++++++++++++++++++++"
#echo $_db
#echo $_db_user
#echo $_cvs_dir
#echo "=============================================="
mkdir $_cvs_dir
cp summary.csv transaction.csv $_cvs_dir
cd $_cvs_dir
for _csv_file in `ls`
do
echo $_csv_file 
 # remove file extension
  _csv_file_extensionless=`echo $_csv_file | sed 's/\(.*\)\..*/\1/'`
echo $_csv_file_extensionless

# define table name
  _table_name="${_csv_file_extensionless}"
echo $_table_name

_header_columns=`head -1 $_csv_file | tr ',' '\n' | sed 's/^"//' | sed 's/"$//' | sed 's/ /_/g'`
_header_columns_string=`head -1 $_csv_file | sed 's/ /_/g' | sed 's/"//g'`

echo $_header_columns
echo $_header_columns_string


# ensure table exists
  mysql -u $_db_user -p$mysql_password $_db << eof
    CREATE TABLE IF NOT EXISTS \`$_table_name\` (
      id int(11) NOT NULL auto_increment,
      PRIMARY KEY  (id)
    ) ENGINE=MyISAM DEFAULT CHARSET=latin1
eof

 # loop through header columns
  for _header in ${_header_columns[@]}
    do
          # add column
    mysql -u $_db_user -p$mysql_password $_db --execute="alter table \`$_table_name\` add column \`$_header\` text"
    done

# import csv into mysql
  mysqlimport --fields-enclosed-by='"' --fields-terminated-by=',' --lines-terminated-by="\n" --columns=$_header_columns_string -u $_db_user -p$mysql_password $_db $_cvs_dir/$_csv_file
done
rm -rf $PWD/DB

echo "ETL process completed successfully!"
# Remove intermediate files

