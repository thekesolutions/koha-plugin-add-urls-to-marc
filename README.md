# koha-plugin-add-urls-to-marc
This plugin provides a way for importing URLs into MARC records in Koha. This is useful when
giving a third party the task to scan your resources and you get from them a CSV file with
the links to the scanned resources (e.g. Internet Archive).

## Usage
The plugin expects a CSV file as input. The file needs to contain the following columns
`biblionumber, url, text`

*biblionumber* must match an existing record in Koha, otherwise it is reported and skipped.
*url* is the URL that will be put in **856$u**
*text* is the text that will be put in **856$z**


## Example file

biblionumber | url | text
-------------|-----|------
1 | https://theke.io | Theke's site
2 | https://koha-community.org | Koha community's site

