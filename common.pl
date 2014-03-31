#!/usr/bin/perl

use strict;
use warnings;

use DBI;

our $DB_NAME = '';
our $DB_HOST = '';
our $DB_USERNAME = '';
our $DB_PASSWORD = ''; 
our $dbh;

sub db_init() {
	$dbh = DBI->connect("DBI:Pg:dbname=$main::DB_NAME;host=$main::DB_HOST", $main::DB_USERNAME, $main::DB_PASSWORD, {'RaiseError' => 1}) or die "Can't connect to db: $DBI::errstr";
	$dbh->do('SET search_path TO finance');
	return $dbh;
}

1;
####

