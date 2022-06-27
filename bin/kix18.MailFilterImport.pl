#!/usr/bin/perl -w
# --
# bin/kix18.ConfigImportExport.pl - exports misc config settings from KIX to file
# Copyright (C) 2006-2022 c.a.p.e. IT GmbH, http://www.cape-it.de/
#
# written/edited by:
# * Torsten(dot)Thau(at)cape(dash)it(dot)de
# *  David(dot)Bormann(at)cape(dash)it(dot)de
# *  Frank(dot)Oberender(at)cape(dash)it(dot)de
#
# --
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU AFFERO General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
# or see http://www.gnu.org/licenses/agpl.txt.
# --

use strict;
use warnings;

use utf8;
use Encode qw/encode decode/;
use File::Basename;
use FindBin qw($RealBin);
use lib dirname($RealBin);

use Config::Simple;
use Getopt::Long;
use MIME::Base64;
use Text::CSV;
use Pod::Usage;
use Data::Dumper;

use KIX18API;


# VERSION
=head1 SYNOPSIS

This script imports Postmaster Filter from KIX17 to KXI18

Use kix18.MailFilterImport.pl --help [other options]


=head1 OPTIONS

=over

=item
--config: path to configuration file instead of command line params
=cut

=item
--url: URL to KIX backend API (e.g. https://t12345-api.kix.cloud)
=cut

=item
--u: KIX user login
=cut

=item
--p: KIX user password
=cut

=item
--verbose: makes the script verbose
=cut

=item
--nossl disables SSL verification on backend connect
=cut

=item
--help show help message
=cut

=item
--od to which directory the output should be written (setting triggers export, using filters)
=cut

=item
--of to which file the output should be written (setting triggers export, using filters)
=cut

=item
--ft export filter: comma separates list of object types (e.g. DynamicField,Job,ObjectAction,ReportDefinition,Template)
=cut

=item
--fn export filter: pattern for object name applied in a LIKE search (e.g. *Close*), requires option "ft" to be set
=cut

=item
--if source file which is uploaded in config import (setting triggers import)
=cut

=item
--im import setting: mode (one value of Default|ForceAdd|OnlyAdd|OnlyUpdate)
=cut


=back


=head1 REQUIREMENTS

The script has been developed using CentOS8 or Ubuntu as target plattform. Following packages must be installed

=over

=item
shell> sudo yum install perl-Config-Simple perl-REST-Client perl-JSO perl-LWP-Protocol-https perl-URI perl-Pod-Usage perl-Getopt-Long
=cut

=item
shell> sudo apt install libconfig-simple-perl librest-client-perl libjson-perl liblwp-protocol-https-perl liburi-perl perl-doc libgetopt-long-descriptive-perl
=cut

=back

=cut

my $Help = 0;
my %Config = ();
$Config{Verbose} = 0;
$Config{ConfigFilePath} = "";
$Config{KIXURL} = "";
$Config{KIXUserName} = "";
$Config{KIXPassword} = "";
$Config{NoSSLVerify} = "";
$Config{KIXPassword} = "";
$Config{Verbose} = "";
$Config{FilterType} = "";
$Config{FilterName} = "";
$Config{ImportFile} = "";
$Config{ImportMode} = "";
$Config{OutputDir} = "";
$Config{OutputFile} = "";

# read some params from command line...
GetOptions(
    "config=s"  => \$Config{ConfigFilePath},
    "url=s"     => \$Config{KIXURL},
    "u=s"       => \$Config{KIXUserName},
    "p=s"       => \$Config{KIXPassword},
    "nossl"     => \$Config{NoSSLVerify},
    "verbose=i" => \$Config{Verbose},
    "help"      => \$Help,
    "if=s"      => \$Config{ImportFile}
);

if ($Help) {
    pod2usage(-verbose => 3);
    exit(-1)
}


# read config file...
my %FileConfig = ();
if ($Config{ConfigFilePath}) {
    print STDOUT "\nReading config file $Config{ConfigFilePath} ..." if ($Config{Verbose});
    Config::Simple->import_from($Config{ConfigFilePath}, \%FileConfig);

    for my $CurrKey (keys(%FileConfig)) {
        my $LocalKey = $CurrKey;
        $LocalKey =~ s/(CSV\.|KIXAPI.|CSVMap.)//g;
        $Config{$LocalKey} = $FileConfig{$CurrKey} if (!$Config{$LocalKey});
    }

}

# check requried params...
for my $CurrKey (qw{KIXURL KIXUserName KIXPassword}) {
    next if ($Config{$CurrKey});
    print STDERR "\nParam $CurrKey required but not defined - aborting.\n\n";
    pod2usage(-verbose => 1);
    exit(-1)
}

$Config{Verbose} = 3;

if ($Config{Verbose} > 1) {
    print STDOUT "\nFollowing configuration is used:\n";
    for my $CurrKey (sort(keys(%Config))) {
        print STDOUT sprintf("\t%30s: " . ($Config{$CurrKey} || '-') . "\n", $CurrKey,);
    }
}


# log into KIX-Backend API
my $KIXClient = KIX18API::Connect(%Config);
exit(-1) if !$KIXClient;

# read JSON File from KIX17 Export
my $mailFilter = _ReadImportFile();

exit if !$mailFilter || ref($mailFilter) ne 'HASH' || !$mailFilter->{MailFilter} || ref($mailFilter->{MailFilter}) ne 'ARRAY';

# convert Hash to Array
my @mailFilters = @{$mailFilter->{MailFilter}};

# get Leght of Array
my $countMailFilters = scalar @mailFilters;

# initial Counter
my $Created = 0;

my $Updated = 0;

my $Skiped = 0;

my $UpdatedErrors = 0;

my $CreatedErrors = 0;

# loop through Mail Filter Data
foreach my $mailfilterData (@mailFilters) {

    # create MailFilter data hash/map from CSV data...
    my %MailFilter = (
        Name           => ($mailfilterData->{Name} || ''),
        Match          => ($mailfilterData->{Match} || ''),
        Set            => ($mailfilterData->{Set} || ''),
        StopAfterMatch => ($mailfilterData->{StopAfterMatch} || ''),
        Comment        => ($mailfilterData->{Comment} || ''),
        ValidID        => ($mailfilterData->{ValidID} || ''),
        ID             => ($mailfilterData->{ID} || '')
    );

    # resolve PostmasterFilter by Name
    my $MailfilterID = KIX18API::MailFilterValueLookup({
        %Config,
        Client => $KIXClient,
        Name   => $MailFilter{Name}
    }) || '';


    if ($MailfilterID) {

        # replace QueueName with ID
        $MailFilter{ID} = $MailfilterID;

        my $Result = KIX18API::UpdateMailFilter(
            { %Config, Client => $KIXClient, MailFilter => \%MailFilter }
        );

        if (!$Result) {
            $UpdatedErrors++;
        }
        elsif ($Result == 1) {
            $Skiped++;
        }
        else {
            $Updated++;
        }

        #print STDOUT "Updated Queue <" . $MailFilter{ID} . " / "
        #    . $MailFilter{Name}
        #    . ">.\n"
        #    if ($Config{Verbose} > 2);
    }
    else {

        my $NewMailFilterID = KIX18API::CreateMailFilter(
            { %Config, Client => $KIXClient, MailFilter => \%MailFilter }
        );
        if ($NewMailFilterID) {
            $Created++;
        }
        else {
            $CreatedErrors++;
        }

    }

}

if ($Config{Verbose} > 2) {
    print STDOUT "countMailFilters: " . $countMailFilters . "\n";
    print STDOUT "Created: " . $Created . "\n";
    print STDOUT "CreatedErrors: " . $CreatedErrors . "\n";
    print STDOUT "Updated: " . $Updated . "\n";
    print STDOUT "Skiped: " . $Skiped . "\n";
    print STDOUT "UpdatedErrors: " . $UpdatedErrors . "\n";
}

print STDOUT "\nDone.\n";
exit(0);


#-------------------------------------------------------------------------------

sub _ReadImportFile {

    my $filename = $Config{ImportFile};

    my $json_text = do {
        open(my $json_fh, "<:encoding(UTF-8)", $filename)
            or die("Can't open \$filename\": $!\n");
        local $/;
        <$json_fh>
    };

    my $json = JSON->new;
    my $data = $json->decode($json_text);

    return $data;
}

1;
