# kix18sync

To provide simple tools to import data into KIX18 by using its REST-API, data sources may be remote DB tables or CSV files.

These scripts are intented to work as external tools accessing KIX only by it's REST-API. They can be run on the docker host running KIX, but this scenario is not the general use case. Keep in mind to give proper configuration of the KIX-REST **Backend** API, that is correct port number if running on the docker host. These script **do not** evaluate your docker setup in environment files in order to run.

## Contents/Structure
- directory `bin`: scripts for data synchronization
- directory `config`: default/sample configuration
- directory `sample`: sample import data (CSV)

## Required Perl Packages

Scripts have been developed using CentOS8 or Ubuntu/Debian as target plattform. Following packages must be installed:

- CentOS/RHEL
```
shell> sudo yum install perl-Config-Simple perl-REST-Client perl-JSO perl-LWP-Protocol-https perl-DBI perl-URI perl-Pod-Usage perl-Getopt-Long
```
- Ubuntu/Debian
```
shell> sudo apt install libconfig-simple-perl librest-client-perl libjson-perl liblwp-protocol-https-perl libdbi-perl liburi-perl perl-doc libgetopt-long-descriptive-perl
```

----
## Sync from Database Source - kix18.DBSync.pl

Script `bin/kix18.DBSync.pl` provides a client for importing data from a remote DB to KIX18 REST-API, supporting Contact and Organisation (so far).

### Required Perl Packages

Depending on the DBMS to be connected, additional packages might be required, e.g.
- CentOS
```
shell> sudo yum install perl-DBD-Pg
shell> sudo yum install perl-DBD-MySQL
shell> sudo yum install perl-DBD-ODBC
```
- Ubuntu/Debian
```
shell> sudo apt install libdbd-pg-perl
shell> sudo apt install libdbd-mysql-perl
shell> sudo apt install libdbd-odbc-perl
```


### Usage
`./bin/kix18.DBSync.pl --config ./config/kix18.DBSync.cfg --ot Contact|Organisation`

The script can be used by referring to a configuration and object type only. Any parameter given by command line overwrites values specified in the config file. Use `kix18.DBSync.pl --help` for a detailed parameter listing.

- `config`: path to configuration file instead of command line params
- `ot`: object to be imported (Contact|Organisation)
- `url`: URL to KIX backend API (e.g. https://t12345-api.kix.cloud)
- `u`: KIX user login
- `p`: KIX user password
- `du`: DBUser  (if not given by config)
- `dp`: DBPassword (if not given by config)
- `verbose`: makes the script verbose
- `help`: show help message


### Configuration

The major configuration has to be placed in a separate config file which is read upon script execution. A sample config might look like this:

```
# KIXAPI configuration
[KIXAPI]
KIXUserName        = "API-User"
KIXPassword        = "API-User-Password"
KIXURL             = http://localhost:20000
Proxy              = ""
APITimeOut         = 30

# DB configuration
[DB]
# DSN is the full DB connection string without username/password
#DSN         = "DBI:mysql:database=MyCRMDB;host=mariadb.server.local;"
#DSN         = "DBI:ODBC:MyODBCDBName"
DSN         = "DBI:Pg:dbname=kix17;host=kix.company.de;"
DBUser      = "SomeDBUser"
DBPassword  = "PASSWORD"

# limit might be useful for testing (only for MySQL/MariaDB or PostgreSQL)...
DBLimit     = "100"

# following sections define the mapping of DB-tables to KIX-API resources
# Table        = "some_customer_user_table"
# Condition is optional and allows to filter relevant DB entries
# Condition    = "WHERE login != ''"
# OtherRessourceAttribute = "DB column name"
# if an attribute is not given in the DB-table it may be set to a fixed value by
# SomeRessourceAttribute = "SET:<fixedvaluehere>"

# Mapping configuration for contact items...
[Contact]
Table        = "some_customer_user"
Condition    = ""
# use condition if you want to sync. only newer entries, e.g.
# Condition    = " create_time > (current_timestamp - 86400)"
Login        = "login"
# use custom row name if a DB row should be used in multiple attributes
# Login        = "email0 AS login"
Email        = "email0"
Firstname    = "first_name"
Lastname     = "last_name"
Title        = "title"
Street       = "addr_street"
City         = "addr_city"
Zip          = "addr_zip"
Country      = "addr_country"
Phone        = "phone1"
Mobile       = "phone2"
Fax          = "fax1"
Comment      = "businessfnct"
PrimaryOrgNo = "customer_id"
ValidID      = "SET:1"

# Mapping configuration for organisation items...
[Organisation]
Table        = "some_org"
Condition    = ""
Number       = "customer_id"
Name         = "name_org"
Comment      = "comments"
Street       = "addr_street"
City         = "addr_city"
Zip          = "addr_zip"
Country      = "addr_country"
Url          = "url"
ValidID      = "SET:1"
```




----
## Sync from CSV-File - kix18.CSVSync.pl

Script `bin/kix18.CSVSync.pl` provides a client for importing data from CSV files to KIX18 REST-API, supporting Contact and Organisation (so far).

### Required Perl Packages

For handling CSV following packages need to be installed additionally:

- CentOS
```
shell> sudo yum install libtext-csv-perl
```
- Ubuntu/Debian
```
shell> sudo apt install perl-Text-CSV
```


### Usage
`./bin/kix18.CSVSync.pl --config ./config/kix18.CSVSync.cfg --ot Contact|Organisation`

The script can be used by referring to a configuration and object type only. Any parameter given by command line overwrites values specified in the config file. Use `kix18.CSVSync.pl --help` for a detailed parameter listing.

- `config`: path to configuration file instead of command line params
- `ot`: object to be imported (Contact|Organisation)
- `url`: URL to KIX backend API (e.g. https://t12345-api.kix.cloud)
- `u`: KIX user login
- `p`: KIX user password
- `verbose`: makes the script verbose
- `help`: show help message
- `i`: source directory from which CSV-files matching name patterns fpr object type are read
- `if`: source file for import (if given, option `i` is ignored)
- `o`: destination directory, where result summary is written
- `r`: if set, import files are deleted after processing

Depending on the object type, any CSV files matching name pattern from the input directory are read. Files containing `Result` are ommited. For each import file a `SourceFileName.Result.csv` is written. Name patterns are ignored if a specific file name is given.

- object type `Asset`: name pattern `*Asset*.csv`
- object type `Contact`: name pattern `*Contact*.csv`
- object type `Organisation`: name pattern `*Org*.csv`

### Configuration

The major configuration has to be placed in a separate config file which is read upon script execution. A sample config might look like this:

```
# KIXAPI configuration
[KIXAPI]
KIXUserName        = "API-User"
KIXPassword        = "API-User-Password"
KIXURL             = http://localhost:20000
Proxy              = ""
APITimeOut         = 30

```
