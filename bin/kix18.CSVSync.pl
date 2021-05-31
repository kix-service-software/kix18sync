#!/usr/bin/perl -w
# --
# bin/kix18.dataimport.pl - imports CSV data into KIX18
# Copyright (C) 2006-2020 c.a.p.e. IT GmbH, http://www.cape-it.de/
#
# written/edited by:
# * Torsten(dot)Thau(at)cape(dash)it(dot)de
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

use DBI;
use Config::Simple;
use Getopt::Long;
use Text::CSV;
use URI::Escape;
use Pod::Usage;
use Data::Dumper;
use REST::Client;
use JSON;


# VERSION
=head1 SYNOPSIS

This script retrieves import selected business object data into a KIX18 by communicating with its REST-API

Use kix18.CSVSync.pl  --ot ObjectType* --help [other options]


=head1 OPTIONS

=over

=item
--ot: ObjectType  (Contact|Organisation|SLA)
=cut

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
--i: input directory
=cut


=item
--if: input file (overrides param input directory)
=cut


=item
--o: output directory
=cut

=item
--fpw: flag, force password reset on user update
=cut

=item
--r: flag, set to remove source file after being processed
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

=back


=head1 REQUIREMENTS

The script has been developed using CentOS8 or Ubuntu as target plattform. Following packages must be installed

=over

=item
shell> sudo yum install perl-Config-Simple perl-REST-Client perl-JSO perl-LWP-Protocol-https perl-DBI perl-URI perl-Pod-Usage perl-Getopt-Long  libtext-csv-perl
=cut

=item
shell> sudo apt install libconfig-simple-perl librest-client-perl libjson-perl liblwp-protocol-https-perl libdbi-perl liburi-perl perl-doc libgetopt-long-descriptive-perl
=cut

=back

=cut

my $Help           = 0;
my %Config         = ();
$Config{Verbose}           = 0;
$Config{RemoveSourceFile}  = 0;
$Config{ConfigFilePath}    = "";
$Config{KIXURL}            = "";
$Config{KIXUserName}       = "";
$Config{KIXPassword}       = "";

# read some params from command line...
GetOptions (
  "config=s"   => \$Config{ConfigFilePath},
  "url=s"      => \$Config{KIXURL},
  "u=s"        => \$Config{KIXUserName},
  "p=s"        => \$Config{KIXPassword},
  "ot=s"       => \$Config{ObjectType},
  "i=s"        => \$Config{CSVInputDir},
  "if=s"       => \$Config{CSVInputFile},
  "o=s"        => \$Config{CSVOutputDir},
  "fpw"        => \$Config{ForcePwReset},
  "r"          => \$Config{RemoveSourceFile},
  "nossl"      => \$Config{NoSSLVerify},
  "verbose=i"  => \$Config{Verbose},
  "help"       => \$Help,
);

if( $Help ) {
  pod2usage( -verbose => 3);
  exit(-1)
}

# APOLOGY-NOTE
# OK, this is getting a bit messy. I do know this is really ugly code.
# I regret not having started a bit more modularized - it sort of evolved from
# a quick need. Someday there will be a re-evolution, but not today :-/.


# read CSV input...
if( $Config{CSVInputFile} ) {
  print STDOUT "\nInput file given - ignoring input directory." if( $Config{Verbose});
  my $basename = basename( $Config{CSVInputFile} );
  my $dirname  = dirname( $Config{CSVInputFile} );
  $Config{CSVInputDir} = $dirname;
  $Config{CSVInputFile} = $basename;
}

# read config file...
my %FileConfig = ();
if( $Config{ConfigFilePath} ) {
    print STDOUT "\nReading config file $Config{ConfigFilePath} ..." if( $Config{Verbose});
    Config::Simple->import_from( $Config{ConfigFilePath}, \%FileConfig);

    for my $CurrKey ( keys( %FileConfig )) {
      my $LocalKey = $CurrKey;
      $LocalKey =~ s/(CSV\.|KIXAPI.|CSVMap.)//g;
      $Config{$LocalKey} = $FileConfig{$CurrKey} if(!$Config{$LocalKey});
    }

}

# check requried params...
for my $CurrKey (qw{KIXURL KIXUserName KIXPassword ObjectType CSVInputDir}) {
  next if($Config{$CurrKey});
  print STDERR "\nParam $CurrKey required but not defined - aborting.\n\n";
  pod2usage( -verbose => 1);
  exit(-1)
}


if( $Config{Verbose} > 1) {
  print STDOUT "\nFollowing configuration is used:\n";
  for my $CurrKey( sort( keys( %Config ) ) ) {
    print STDOUT sprintf( "\t%30s: ".($Config{$CurrKey} || '-')."\n" , $CurrKey, );
  }
}

# read source CSV file...
my $CSVDataRef = _ReadSources( { %Config} );
exit(-1) if !$CSVDataRef;


# log into KIX-Backend API
my $KIXClient = _KIXAPIConnect( %Config  );
exit(-1) if !$KIXClient;


# lookup validities...
my %ValidList = _KIXAPIValidList(
  { %Config, Client => $KIXClient}
);
my %RevValidList = reverse(%ValidList);



my $Result = 0;

# import CSV-data...
my $ResultData = $CSVDataRef;
if ( $Config{ObjectType} eq 'Asset') {

  # lookup asset classes...
  my %AssetClassList = _KIXAPIGeneralCatalogList(
    { %Config, Client => $KIXClient, Class => 'ITSM::ConfigItem::Class'}
  );

  # lookup deployment states...
  my %DeplStateList = _KIXAPIGeneralCatalogList(
    { %Config, Client => $KIXClient, Class => 'ITSM::ConfigItem::DeploymentState'}
  );

  # lookup incident states...
  my %InciStateList = _KIXAPIGeneralCatalogList(
    { %Config, Client => $KIXClient, Class => 'ITSM::Core::IncidentState'}
  );

  print STDERR "\nAsset import not supported (yet) - aborting.\n\n";
  pod2usage( -verbose => 1);
  exit(-1)

}
elsif ( $Config{ObjectType} eq 'SLA') {

  my %CalendarList = _KIXAPICalendarList(
    { %Config, Client => $KIXClient }
  );

  # there is no SLA-search method, so we jsut get all SLAs now...
  my %SLAList = _KIXAPIListSLA(
    { %Config, Client => $KIXClient }
  );

  # process import lines
  FILE:
  for my $CurrFile ( keys( %{$CSVDataRef}) ) {

    my $LineCount = 0;

    LINE:
    for my $CurrLine ( @{$CSVDataRef->{$CurrFile}} ) {

      # skip first line (ignore header)...
      if ( $LineCount < 1) {
        $LineCount++;
        next;
      }

      # prepare validity..
      my $SLAValidId = 1;
      if( $Config{'SLA.ColIndex.ValidID'} =~/^SET\:(.+)/) {
        $SLAValidId = $1;
      }
      else {
        $SLAValidId = $CurrLine->[$Config{'SLA.ColIndex.ValidID'}];
      }
      if( $SLAValidId !~ /^\d+$/ && $RevValidList{ $SLAValidId } ) {
        $SLAValidId     = $RevValidList{ $SLAValidId } || '';
      }
      else {
        $SLAValidId = "";
      };

      # create SLA data hash/map from CSV data...
      my %SLA = (
          Name                => ($CurrLine->[$Config{'SLA.ColIndex.Name'}] || ''),
          Calendar            => ($CurrLine->[$Config{'SLA.ColIndex.Calendar'}] || ''),
          FirstResponseTime   => ($CurrLine->[$Config{'SLA.ColIndex.FirstResponseTime'}] || ''),
          FirstResponseNotify => ($CurrLine->[$Config{'SLA.ColIndex.FirstResponseNotify'}] || ''),
          SolutionTime        => ($CurrLine->[$Config{'SLA.ColIndex.SolutionTime'}] || ''),
          SolutionTimeNotify  => ($CurrLine->[$Config{'SLA.ColIndex.SolutionTimeNotify'}] || ''),
          Comment             => ($CurrLine->[$Config{'SLA.ColIndex.Comment'}] || ''),
          ValidID             => $SLAValidId,
      );

      # replace calendar name by calendar index...
      $SLA{Calendar} = $CalendarList{$SLA{Calendar}} || '';

      # cleanup empty values...
      for my $CurrKey ( keys(%SLA) ) {
          $SLA{$CurrKey} = undef if( !length($SLA{$CurrKey}) );
      }

      # update existing SLA...
      if( $SLAList{ $CurrLine->[$Config{'SLA.ColIndex.Name'}]} ) {

        my %SLAData = %{$SLAList{ $CurrLine->[$Config{'SLA.ColIndex.Name'}]}};

        if( $SLAData{"Internal"} ) {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, 'Cannot update internal entry.');
          $LineCount++;
          next LINE;
        }

        $SLA{ID} = $SLAData{ID};
        my $Result = _KIXAPIUpdateSLA(
          { %Config, Client => $KIXClient, SLA => \%SLA }
        );

        if( !$Result) {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, 'Update failed.');
        }
        elsif ( $Result == 1 ) {
          push( @{$CurrLine}, 'no update required');
          push( @{$CurrLine}, $SLA{ID});
        }
        else {
          push( @{$CurrLine}, 'update');
          push( @{$CurrLine}, $SLA{ID});
        }

        print STDOUT "$LineCount: Updated SLA <".$SLA{ID}." / "
          . $SLA{Name}
          . ">.\n"
        if( $Config{Verbose} > 2);

      }
      # create new SLA...
      else {
        my $NewSLAID = _KIXAPICreateSLA(
          { %Config, Client => $KIXClient, SLA => \%SLA }
        );

        if ( $NewSLAID ) {
          push( @{$CurrLine}, 'created');
          push( @{$CurrLine}, $NewSLAID);
        }
        else {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, 'Create failed.');
        }

        print STDOUT "$LineCount: Created SLA <$NewSLAID / "
          .$SLA{Name}. ">.\n"
          if( $Config{Verbose} > 2);
      }

      $LineCount++;

    }
  }


}
elsif ( $Config{ObjectType} eq 'Contact') {

  my %OrgIDCache = ();

  # lookup DFs for organizations...
  my %DFList = _KIXAPIDynamicFieldList(
    { %Config, Client => $KIXClient, ObjectType => 'Contact'}
  );
  my %IgnoredDF = ();

  # lookup permission roles...
  my %RoleList = _KIXAPIRoleList(
    { %Config, Client => $KIXClient}
  );

  # process import lines
  for my $CurrFile ( keys( %{$CSVDataRef}) ) {

    my $LineCount = 0;

    for my $CurrLine ( @{$CSVDataRef->{$CurrFile}} ) {

      # skip first line (ignore header)...
      if ( $LineCount < 1) {
        $LineCount++;
        next;
      }

      # ------------------------------------------------------------------------
      # handle user account
      my $ContactUserID = "";
      if( $CurrLine->[$Config{'Contact.ColIndex.Login'}] ) {

          # extract role names
          my $RolesStrg = $CurrLine->[$Config{'Contact.ColIndex.Roles'}];
          my @RoleArr = split( ',', $RolesStrg );

          # get IsAgent/-Customer values...
          my $IsAgent    =  "0";
          my $IsCustomer =  "0";
          if( $Config{'Contact.ColIndex.IsAgent'} =~/^SET\:(.+)/) {
            $IsAgent = $1 || "0";
          }
          else {
            $IsAgent = $CurrLine->[$Config{'Contact.ColIndex.IsAgent'}] || "0";
          }

          if( $Config{'Contact.ColIndex.IsCustomer'} =~/^SET\:(.+)/) {
            $IsCustomer = $1 || "0";
          }
          else{
            $IsCustomer =  $CurrLine->[$Config{'Contact.ColIndex.IsCustomer'}] || "0";
          }

          # assign default roles based on IsAgent/IsCustomer status...
          push( @RoleArr, 'Agent User') if( $IsAgent );
          push( @RoleArr, 'Customer') if( $IsCustomer );

          # get role ids for user...
          my @RoleIDsArr = qw{};
          ROLENAME:
          for my $CurrRoleName ( @RoleArr ) {
              next ROLENAME if( !$RoleList{$CurrRoleName});
              next ROLENAME if( !$RoleList{$CurrRoleName}->{ID} );

              # skip role if not fitting IsAgent/IsCustomer status...
              next ROLENAME if( !$IsAgent && !$IsCustomer);
              next ROLENAME if( $RoleList{$CurrRoleName}->{Agent} && !$IsAgent);
              next ROLENAME if( $RoleList{$CurrRoleName}->{Customer} && !$IsCustomer);

              push( @RoleIDsArr, $RoleList{$CurrRoleName}->{ID} ) ;
          }

          if( $Config{Verbose} > 4) {
            print STDOUT "\nUserLogin "
              .($CurrLine->[$Config{'Contact.ColIndex.Login'}] || '-')
              ." (IsAgent=$IsAgent /"
              ." IsCustomer=$IsCustomer) with "
              ." roles (".join( ", ", @RoleArr).")"
              ." with role IDs (".join( ", ", @RoleIDsArr).")";
          }

          # set user invalid if neither Agent nor Customer...
          my $IsValidUser = $IsAgent || $IsCustomer || '2';

          # set user password...
          # TO DO - generate some pw if not given...
          my $UserPw = $CurrLine->[$Config{'Contact.ColIndex.Password'}] || 'Passw0rd!';

          # build data hash
          my %User = (
              UserLogin  => $CurrLine->[$Config{'Contact.ColIndex.Login'}],
              ValidID    => $IsValidUser,
              IsAgent    => $IsAgent,
              IsCustomer => $IsCustomer,
          );
          if( scalar(@RoleIDsArr) ) {
            $User{RoleIDs} = \@RoleIDsArr;
          }
          for my $CurrKey ( keys(%User) ) {
              $User{$CurrKey} = undef if( !length($User{$CurrKey}) );
          }

          # search user...
          my %SearchResult = _KIXAPISearchUser({
            %Config,
            Client      => $KIXClient,
            SearchValue => $CurrLine->[$Config{'Contact.ColIndex.Login'}] || '',
          });
          # handle errors...
          if ( $SearchResult{Msg} ) {
            push( @{$CurrLine}, 'ERROR');
            push( @{$CurrLine}, $SearchResult{Msg});
          }

          # update existing user...
          elsif ( $SearchResult{ID} ) {
            $ContactUserID = $SearchResult{ID};

            if( $Config{ForcePwReset} ) {
                $User{UserPw} = $UserPw;
            }
            $User{ID} = $SearchResult{ID};
            my $UserID = _KIXAPIUpdateUser(
              { %Config, Client => $KIXClient, User => \%User }
            );

            if( !$UserID) {
              push( @{$CurrLine}, 'ERROR');
              push( @{$CurrLine}, 'user update failed.');
            }
            elsif ( $UserID == 1 ) {
              push( @{$CurrLine}, 'no user update required');
              push( @{$CurrLine}, $SearchResult{Msg});
            }
            else {
              push( @{$CurrLine}, 'user updated');
              push( @{$CurrLine}, $SearchResult{Msg});
            }

            print STDOUT "$LineCount: Updated user <$UserID> for <Login "
              . $User{UserLogin}. ">.\n"
            if( $Config{Verbose} > 2);


          }
          # create new user...
          else {
            $User{UserPw} = $UserPw;
            my $NewUserID = _KIXAPICreateUser(
              { %Config, Client => $KIXClient, User => \%User }
            ) || '';
            $ContactUserID = $NewUserID;

            if ( $NewUserID ) {
              push( @{$CurrLine}, 'user created');
              push( @{$CurrLine}, $SearchResult{Msg});
            }
            else {
              push( @{$CurrLine}, 'ERROR');
              push( @{$CurrLine}, 'user create failed.');
            }

            print STDOUT "$LineCount: Created user <$NewUserID> for <Login "
              . $User{UserLogin}. ">.\n"
            if( $Config{Verbose} > 2);
          }



      }
      else {
          # no contact created/updated...
          push( @{$CurrLine}, '');
      }

      # ------------------------------------------------------------------------
      # handle contact
      if( !$CurrLine->[$Config{'Contact.SearchColIndex'}] ) {
        push( @{$CurrLine}, 'ERROR');
        push( @{$CurrLine}, 'Identifier missing.');
        print STDOUT "$LineCount: identifier missing.\n";
        next;
      }

      my $OrgID = undef;

      if( $OrgIDCache{ $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}] } ) {
        $OrgID = $OrgIDCache{ $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}] };

      }
      elsif( $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}] ) {

        my %OrgID = _KIXAPISearchOrg({
          %Config,
          Client      => $KIXClient,
          SearchValue => $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}] || '-',
        });

        if ( $OrgID{ID} ) {
          $OrgID = $OrgID{ID};
          $OrgIDCache{ $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}] } = $OrgID;
        }
        else {
          print STDOUT "$LineCount: no organization found for <"
            . $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}]
            . ">.\n"
        }
      }

      my $ContactValidId = 1;
      if( $Config{'Contact.ColIndex.ValidID'} =~/^SET\:(.+)/) {
        $ContactValidId = $1;
      }
      else {
        $ContactValidId = $CurrLine->[$Config{'Contact.ColIndex.ValidID'}];
      }

      my %Contact = (
          City            => $CurrLine->[$Config{'Contact.ColIndex.City'}],
          Comment         => $CurrLine->[$Config{'Contact.ColIndex.Comment'}],
          Country         => $CurrLine->[$Config{'Contact.ColIndex.Country'}],
          Email           => $CurrLine->[$Config{'Contact.ColIndex.Email'}],
          Fax             => $CurrLine->[$Config{'Contact.ColIndex.Fax'}],
          Firstname       => $CurrLine->[$Config{'Contact.ColIndex.Firstname'}],
          Lastname        => $CurrLine->[$Config{'Contact.ColIndex.Lastname'}],
          Login           => $CurrLine->[$Config{'Contact.ColIndex.Login'}],
          Mobile          => $CurrLine->[$Config{'Contact.ColIndex.Mobile'}],
          Phone           => $CurrLine->[$Config{'Contact.ColIndex.Phone'}],
          Street          => $CurrLine->[$Config{'Contact.ColIndex.Street'}],
          Title           => $CurrLine->[$Config{'Contact.ColIndex.Title'}],
          ValidID         => $ContactValidId,
          Zip             => $CurrLine->[$Config{'Contact.ColIndex.Zip'}],
      );

      # now get all all dynamic DynamicFields
      my @LineDFs = qw{};

      CONFIGKEY:
      for my $CurrKey ( keys(%Config)) {
        next CONFIGKEY if( $CurrKey !~ /^Contact.ColIndex.DynamicField_(.+)/);
        my $CurrDFKey = $1;

        next CONFIGKEY if( $IgnoredDF{$CurrDFKey} );

        # skip if DF does not exists...
        if( !$DFList{$CurrDFKey} ) {
          print STDERR "\nDynamic Field <$CurrDFKey> does not exist for object type - ignoring column.";
          # and remeber to skip it in next lines..
          $IgnoredDF{$CurrDFKey} = 1;
          next CONFIGKEY;
        }

        my %CurrDF = ();
        my @CurrDFValArr = qw{};
        my $CurrDFValStr = $CurrLine->[$Config{$CurrKey}] || '';
        if( $CurrDFValStr ) {
          @CurrDFValArr = [$CurrDFValStr];
          if( $Config{DFArrayCommaSplit} ) {
            @CurrDFValArr = split( ',', $CurrDFValStr);
          }
        }

        $CurrDF{"Name"}  = $CurrDFKey;
        $CurrDF{"Value"} = \@CurrDFValArr;

        if( scalar(@CurrDFValArr) ) {
          push(@LineDFs, \%CurrDF);
        }
      }
      if( scalar(@LineDFs) ) {
        $Contact{DynamicFields} = \@LineDFs;
      }

      # assign user login if given...
      if( $ContactUserID ) {
          $Contact{AssignedUserID} = $ContactUserID;
      }

      # cleanup empty values...
      for my $CurrKey ( keys(%Contact) ) {
          $Contact{$CurrKey} = undef if( !length($Contact{$CurrKey}) );
      }

      if( $OrgID ) {
        my @OrgIDs = ();
        push( @OrgIDs, $OrgID);
        $Contact{OrganisationIDs} = \@OrgIDs;
        $Contact{PrimaryOrganisationID} = $OrgID;
      }

      # search contact...
      my %SearchResult = _KIXAPISearchContact({
        %Config,
        Client      => $KIXClient,
        SearchValue => $CurrLine->[$Config{'Contact.SearchColIndex'}] || '-'
      });

      # handle errors...
      if ( $SearchResult{Msg} ) {
        push( @{$CurrLine}, 'ERROR');
        push( @{$CurrLine}, $SearchResult{Msg});

      }

      # update existing $Contact...
      elsif ( $SearchResult{ID} ) {
        $Contact{ID} = $SearchResult{ID};
        my $ContactID = _KIXAPIUpdateContact(
          { %Config, Client => $KIXClient, Contact => \%Contact }
        );

        if( !$ContactID) {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, 'Update failed.');
        }
        elsif ( $ContactID == 1 ) {
          push( @{$CurrLine}, 'no update required');
          push( @{$CurrLine}, $SearchResult{Msg});
        }
        else {
          push( @{$CurrLine}, 'update');
          push( @{$CurrLine}, $SearchResult{Msg});
        }

        print STDOUT "$LineCount: Updated contact <$SearchResult{ID}> for <Email "
          . $Contact{Email}
          . ">.\n"
        if( $Config{Verbose} > 2);
      }
      # create new contact...
      else {

        my $NewContactID = _KIXAPICreateContact(
          { %Config, Client => $KIXClient, Contact => \%Contact }
        ) || '';

        if ( $NewContactID ) {
          push( @{$CurrLine}, 'created');
          push( @{$CurrLine}, $SearchResult{Msg});
        }
        else {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, 'Create failed.');
        }

        print STDOUT "$LineCount: Created contact <$NewContactID> for <Email "
          . $Contact{Email}. ">.\n"
        if( $Config{Verbose} > 2);
      }

      $LineCount++;

    }
  }

}
elsif ( $Config{ObjectType} eq 'Organisation') {



  # lookup DFs for organizations...
  my %DFList = _KIXAPIDynamicFieldList(
    { %Config, Client => $KIXClient, ObjectType => 'Organisation'}
  );
  my %IgnoredDF = ();

  # process import lines
  for my $CurrFile ( keys( %{$CSVDataRef}) ) {

    my $LineCount = 0;

    for my $CurrLine ( @{$CSVDataRef->{$CurrFile}} ) {

      # skip first line (ignore header)...
      if ( $LineCount < 1) {
        $LineCount++;
        next;
      }

      if( !$CurrLine->[$Config{'Org.SearchColIndex'}] ) {
        push( @{$CurrLine}, 'ERROR');
        push( @{$CurrLine}, 'Identifier missing.');
        print STDOUT "$LineCount: identifier missing.\n";
        next;
      }

      my $ValidId = 1;
      if( $Config{'Org.ColIndex.ValidID'} =~/^SET\:(.+)/) {
        $ValidId = $1;
      }
      else {
        $ValidId = $CurrLine->[$Config{'Org.ColIndex.ValidID'}];
      }

      # get fixed organization attributes..
      my %Organization = (
          City            => $CurrLine->[$Config{'Org.ColIndex.City'}],
          Number   => $CurrLine->[$Config{'Org.ColIndex.Number'}],
          Name     => $CurrLine->[$Config{'Org.ColIndex.Name'}],
          Comment  => $CurrLine->[$Config{'Org.ColIndex.Comment'}],
          Street   => $CurrLine->[$Config{'Org.ColIndex.Street'}],
          City     => $CurrLine->[$Config{'Org.ColIndex.City'}],
          Zip      => $CurrLine->[$Config{'Org.ColIndex.Zip'}],
          Country  => $CurrLine->[$Config{'Org.ColIndex.Country'}],
          Url      => $CurrLine->[$Config{'Org.ColIndex.Url'}],
          ValidID  => $ValidId,
      );


      # now get all all dynamic DynamicFields
      my @LineDFs = qw{};

      CONFIGKEY:
      for my $CurrKey ( keys(%Config)) {
        next CONFIGKEY if( $CurrKey !~ /^Org.ColIndex.DynamicField_(.+)/);
        my $CurrDFKey = $1;

        next CONFIGKEY if( $IgnoredDF{$CurrDFKey} );

        # skip if DF does not exists...
        if( !$DFList{$CurrDFKey} ) {
          print STDERR "\nDynamic Field <$CurrDFKey> does not exist for object type - ignoring column.";
          # and remeber to skip it in next lines..
          $IgnoredDF{$CurrDFKey} = 1;
          next CONFIGKEY;
        }

        my %CurrDF = ();
        my @CurrDFValArr = qw{};
        my $CurrDFValStr = $CurrLine->[$Config{$CurrKey}] || '';
        if( $CurrDFValStr ) {
          @CurrDFValArr = [$CurrDFValStr];
          if( $Config{DFArrayCommaSplit} ) {
            @CurrDFValArr = split( ',', $CurrDFValStr);
          }
        }

        $CurrDF{"Name"}  = $CurrDFKey;
        $CurrDF{"Value"} = \@CurrDFValArr;

        if( scalar(@CurrDFValArr) ) {
          push(@LineDFs, \%CurrDF);
        }
      }
      if( scalar(@LineDFs) ) {
        $Organization{DynamicFields} = \@LineDFs;
      }
      # DynamicFields => [
      #   {
      #     "Name"  => "Keywords",
      #     "Value" => [ "Problem", "Server"]
      #   }
      # ],

      # cleanup empty values...
      for my $CurrKey ( keys(%Organization) ) {
          $Organization{$CurrKey} = undef if( !length($Organization{$CurrKey}) );
      }

      # search organization...
      my %SearchResult = _KIXAPISearchOrg({
        %Config,
        Client      => $KIXClient,
        SearchValue => $CurrLine->[$Config{'Org.SearchColIndex'}] || '-'
      });

      # handle errors...
      if ( $SearchResult{Msg} ) {
        push( @{$CurrLine}, 'ERROR');
        push( @{$CurrLine}, $SearchResult{Msg});
      }

      # update existing organisation...
      elsif ( $SearchResult{ID} ) {
        $Organization{ID} = $SearchResult{ID};
        my $OrgID = _KIXAPIUpdateOrg(
          { %Config, Client => $KIXClient, Organization => \%Organization }
        );

        if( !$OrgID) {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, 'Update failed.');
        }
        elsif ( $OrgID == 1 ) {
          push( @{$CurrLine}, 'no update required');
          push( @{$CurrLine}, $SearchResult{Msg});
        }
        else {
          push( @{$CurrLine}, 'update');
          push( @{$CurrLine}, $SearchResult{Msg});
        }

        print STDOUT "$LineCount: Updated organisation <$OrgID> for <"
          . $Organization{Number}
          . ">.\n"
          if( $Config{Verbose} > 2);
      }

      # create new organisation...
      else {

        my $NewOrgID = _KIXAPICreateOrg(
          { %Config, Client => $KIXClient, Organization => \%Organization }
        );

        if ( $NewOrgID ) {
          push( @{$CurrLine}, 'created');
          push( @{$CurrLine}, $SearchResult{Msg});
        }
        else {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, 'Create failed.');
        }

        print STDOUT "$LineCount: Created organisation <$NewOrgID> for <"
          .$Organization{Number}. ">.\n"
          if( $Config{Verbose} > 2);
      }

      $LineCount++;
    }
  }

}
else {
  print STDERR "\nUnknown object type '$Config{ObjectType}' - aborting.\n\n";
  pod2usage( -verbose => 1);
  exit(-1)
}


# write result file and cleanup...
_WriteResult( { %Config, Data => $ResultData} );


print STDOUT "\nDone.\n";
exit(0);




# ------------------------------------------------------------------------------
# KIX API Helper FUNCTIONS
sub _KIXAPIConnect {
  my (%Params) = @_;
  my $Result = 0;

  # connect to webservice
  my $AccessToken = "";
  my $Headers = {Accept => 'application/json', };
  my $RequestBody = {
  	"UserLogin" => $Config{KIXUserName},
  	"Password" =>  $Config{KIXPassword},
  	"UserType" => "Agent"
  };

  my $Client = REST::Client->new(
    host    => $Config{KIXURL},
    timeout => $Config{APITimeOut} || 15,
  );
  $Client->getUseragent()->proxy(['http','https'], $Config{Proxy});

  if( $Config{NoSSLVerify} ) {
    $Client->getUseragent()->ssl_opts(verify_hostname => 0);
    $Client->getUseragent()->ssl_opts(SSL_verify_mode => 0);
  }

  $Client->POST(
      "/api/v1/auth",
      to_json( $RequestBody ),
      $Headers
  );

  if( $Client->responseCode() ne "201") {
    print STDERR "\nCannot login to $Config{KIXURL}/api/v1/auth (user: "
      .$Config{KIXUserName}.". Response ".$Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    $AccessToken = $Response->{Token};
    print STDOUT "Connected to $Config{KIXURL}/api/v1/ (user: "
      ."$Config{KIXUserName}).\n" if( $Config{Verbose} > 1);

  }

  $Client->addHeader('Accept', 'application/json');
  $Client->addHeader('Content-Type', 'application/json');
  $Client->addHeader('Authorization', "Token ".$AccessToken);

  return $Client;
}




#-------------------------------------------------------------------------------
# SLA HANDLING FUNCTIONS KIX-API
sub _KIXAPIListSLA {
  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};

  $Params{Client}->GET( "/api/v1/system/slas");

  if( $Client->responseCode() ne "200") {
    print STDERR "\nSearch for roles failed (Response ".$Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    for my $CurrItem ( @{$Response->{SLA}}) {
      my %SLAData = ();
      $SLAData{"Calendar"}            = $CurrItem->{"Calendar"};
      $SLAData{"Comment"}             = $CurrItem->{"Comment"};
      $SLAData{"FirstResponseNotify"} = $CurrItem->{"FirstResponseNotify"};
      $SLAData{"FirstResponseTime"}   = $CurrItem->{"FirstResponseTime"};
      $SLAData{"ID"}                  = $CurrItem->{"ID"};
      $SLAData{"Internal"}            = $CurrItem->{"Internal"};
      $SLAData{"Name"}                = $CurrItem->{"Name"};
      $SLAData{"SolutionNotify"}      = $CurrItem->{"SolutionNotify"};
      $SLAData{"SolutionTime"}        = $CurrItem->{"SolutionTime"};
      $SLAData{"ValidID"}             = $CurrItem->{"ValidID"};

      $Result{ $CurrItem->{Name} } = \%SLAData;
    }
  }

  return %Result;
}



sub _KIXAPIUpdateSLA {

  my %Params = %{$_[0]};
  my $Result = 0;

  $Params{SLA}->{ValidID} = $Params{SLA}->{ValidID} || 1;

  my $RequestBody = {
    "SLA" => {
        %{$Params{SLA}}
    }
  };

  $Params{Client}->PATCH(
      "/api/v1/system/slas/".$Params{SLA}->{ID},
      encode("utf-8",to_json( $RequestBody ))
  );

  #  update ok...
  if( $Params{Client}->responseCode() eq "200") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{SLAID};
  }
  else {
    print STDERR "Updating SLA failed (Response ".$Params{Client}->responseCode().")!";
    print STDERR "\nData submitted: ".Dumper($RequestBody)."\n";

  }

  return $Result;

}



sub _KIXAPICreateSLA {

  my %Params = %{$_[0]};
  my $Result = 0;

  $Params{SLA}->{ValidID} = $Params{SLA}->{ValidID} || 1;

  my $RequestBody = {
    "SLA" => {
        %{$Params{SLA}}
    }
  };
  $Params{Client}->POST(
      "/api/v1/system/slas",
      encode("utf-8", to_json( $RequestBody ))
  );

  if( $Params{Client}->responseCode() ne "201") {
    print STDERR "\nCreating SLA failed (Response ".$Params{Client}->responseCode().")!";
    print STDERR "\nData submitted: ".Dumper($RequestBody)."\n";

    $Result = 0;
  }
  else {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{SLAID};
  }

  return $Result;

}



#-------------------------------------------------------------------------------
# CONTACT HANDLING FUNCTIONS KIX-API
sub _KIXAPISearchContact {

    my %Params = %{$_[0]};
    my %Result = (
       ID => 0,
       Msg => ''
    );
    my $Client = $Params{Client};

    my @ResultItemData = qw{};
    my @Conditions = qw{};

    my $IdentAttr  = $Params{Identifier} || "";
    my $IdentStrg  = $Params{SearchValue} || "";

    print STDOUT "Search contact by Email EQ '$IdentStrg'"
      .".\n" if( $Config{Verbose} > 3);

    push( @Conditions,
      {
        "Field"    => "Email",
        "Operator" => "EQ",
        "Type"     => "STRING",
        "Value"    => $IdentStrg
      }
    );

    my $Query = {};
    $Query->{Contact}->{AND} =\@Conditions;
    my @QueryParams = (
      "search=".uri_escape( to_json( $Query)),
    );
    my $QueryParamStr = join( ";", @QueryParams);

    $Params{Client}->GET( "/api/v1/contacts?$QueryParamStr");

    if( $Client->responseCode() ne "200") {
      $Result{Msg} = "Search for contacts failed (Response ".$Client->responseCode().")!";
    }
    else {
      my $Response = from_json( $Client->responseContent() );
      if( scalar(@{$Response->{Contact}}) > 1 ) {
        $Result{Msg} = "More than on item found for identifier.";
      }
      elsif( scalar(@{$Response->{Contact}}) == 1 ) {
        $Result{ID} = $Response->{Contact}->[0]->{ID};
      }
    }

   return %Result;
}



sub _KIXAPIUpdateContact {

  my %Params = %{$_[0]};
  my $Result = 0;

  $Params{Contact}->{ValidID} = $Params{Contact}->{ValidID} || 1;

  my $RequestBody = {
    "Contact" => {
        %{$Params{Contact}}
    }
  };

  $Params{Client}->PATCH(
      "/api/v1/contacts/".$Params{Contact}->{ID},
      encode("utf-8",to_json( $RequestBody ))
    );

  #  update ok...
  if( $Params{Client}->responseCode() eq "200") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{ContactID};
  }
  else {
    print STDERR "Updating contact failed (Response ".$Params{Client}->responseCode().")!\n";
    print STDERR "\nRequestBody: $RequestBody";
    print STDERR "\nRequestBody: ".Dumper($Params{Contact});
    exit(-1);
  }

  return $Result;

}



sub _KIXAPICreateContact {

  my %Params = %{$_[0]};
  my $Result = 0;

  $Params{Contact}->{ValidID} = $Params{Contact}->{ValidID} || 1;

  my $RequestBody = {
    "Contact" => {
        %{$Params{Contact}}
    }
  };

  $Params{Client}->POST(
      "/api/v1/contacts",
      encode("utf-8",to_json( $RequestBody ))
  );

  if( $Params{Client}->responseCode() ne "201") {
    print STDERR "\nCreating contact failed (Response ".$Params{Client}->responseCode().")!\n";
    $Result = 0;
  }
  else {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{ContactID};
  }

  return $Result;

}



#-------------------------------------------------------------------------------
# ORGANISATION HANDLING FUNCTIONS KIX-API
sub _KIXAPISearchOrg {

    my %Params = %{$_[0]};
    my %Result = (
       ID => 0,
       Msg => ''
    );
    my $Client = $Params{Client};

    my @ResultItemData = qw{};
    my @Conditions = qw{};

    my $IdentAttr  = $Params{Identifier} || "";
    my $IdentStrg  = $Params{SearchValue} || "";

    print STDOUT "Search organisation by Number EQ '$IdentStrg'"
      .".\n" if( $Config{Verbose} > 2);

    push( @Conditions,
      {
        "Field"    => "Number",
        "Operator" => "EQ",
        "Type"     => "STRING",
        "Value"    => $IdentStrg
      }
    );

    my $Query = {};
    $Query->{Organisation}->{AND} =\@Conditions;
    my @QueryParams = qw{};
    @QueryParams =  ("search=".uri_escape( to_json( $Query)),);

    my $QueryParamStr = join( ";", @QueryParams);

    $Params{Client}->GET( "/api/v1/organisations?$QueryParamStr");

    # this is a q&d workaround for occasionally 500 response which cannot be
    # explained yet...
    if( $Client->responseCode() eq "500") {
      $Params{Client}->GET( "/api/v1/organisations?$QueryParamStr");
    }

    if( $Client->responseCode() ne "200") {
      $Result{Msg} = "Search for organisations failed (Response ".$Client->responseCode().")!";
      exit(0);
    }
    else {
      my $Response = from_json( $Client->responseContent() );

      if( scalar(@{$Response->{Organisation}}) > 1 ) {
        $Result{Msg} = "More than on item found for identifier.";
      }
      elsif( scalar(@{$Response->{Organisation}}) == 1 ) {
        $Result{ID} = $Response->{Organisation}->[0]->{ID};
      }
    }
   return %Result;
}



sub _KIXAPIUpdateOrg {

  my %Params = %{$_[0]};
  my $Result = 0;

  $Params{Organization}->{ValidID} = $Params{Organization}->{ValidID} || 1;

  my $RequestBody = {
    "Organisation" => {
        %{$Params{Organization}}
    }
  };

  $Params{Client}->PATCH(
      "/api/v1/organisations/".$Params{Organization}->{ID},
      encode("utf-8",to_json( $RequestBody ))
  );

  #  update ok...
  if( $Params{Client}->responseCode() eq "200") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{OrganisationID};
  }
  else {
    print STDERR "Updating contact failed (Response ".$Params{Client}->responseCode().")!\n";
  }

  return $Result;

}



sub _KIXAPICreateOrg {

  my %Params = %{$_[0]};
  my $Result = 0;

  $Params{Organization}->{ValidID} = $Params{Organization}->{ValidID} || 1;


  my $RequestBody = {
    "Organisation" => {
        %{$Params{Organization}}
    }
  };


  $Params{Client}->POST(
      "/api/v1/organisations",
      encode("utf-8", to_json( $RequestBody ))
  );

  if( $Params{Client}->responseCode() ne "201") {
    print STDERR "\nCreating organisation failed (Response ".$Params{Client}->responseCode().")!\n";
    $Result = 0;
  }
  else {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{OrganisationID};
  }

  return $Result;

}



#-------------------------------------------------------------------------------
# CONTACT HANDLING FUNCTIONS KIX-API
sub _KIXAPIRoleList {

  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};

  $Params{Client}->GET( "/api/v1/system/roles");

  if( $Client->responseCode() ne "200") {
    print STDERR "\nSearch for roles failed (Response ".$Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    for my $CurrItem ( @{$Response->{Role}}) {

      my %RoleData = ();
      if( $CurrItem->{UsageContextList}
          && ref($CurrItem->{UsageContextList}) eq 'ARRAY')
      {
        %RoleData = map { $_ => 1 } @{$CurrItem->{UsageContextList}};
      }
      $RoleData{ID} = $CurrItem->{ID};

      $Result{ $CurrItem->{Name} } = \%RoleData;
    }
    # RoleName => {
    #   ID       => 123, # required
    #   Agent    => 1,   # optional
    #   Customer => 1,   # optional
    # }

  }

  return %Result;
}



sub _KIXAPISearchUser {

    my %Params = %{$_[0]};
    my %Result = (
       ID => 0,
       Msg => ''
    );
    my $Client = $Params{Client};

    my @ResultItemData = qw{};
    my @Conditions = qw{};

    my $IdentAttr  = $Params{Identifier} || "";
    my $IdentStrg  = $Params{SearchValue} || "";

    print STDOUT "Search user by UserLogin EQ '$IdentStrg'"
      .".\n" if( $Config{Verbose} > 3);

    push( @Conditions,
      {
        "Field"    => "UserLogin",
        "Operator" => "EQ",
        "Type"     => "STRING",
        "Value"    => $IdentStrg
      }
    );

    my $Query = {};
    $Query->{User}->{AND} =\@Conditions;
    my @QueryParams = (
      "search=".uri_escape( to_json( $Query)),
    );
    my $QueryParamStr = join( ";", @QueryParams);

    $Params{Client}->GET( "/api/v1/system/users?$QueryParamStr");

    if( $Client->responseCode() ne "200") {
      $Result{Msg} = "Search for users failed (Response ".$Client->responseCode().")!";
    }
    else {
      my $Response = from_json( $Client->responseContent() );
      if( scalar(@{$Response->{User}}) > 1 ) {
        $Result{Msg} = "More than on item found for identifier.";
      }
      elsif( scalar(@{$Response->{User}}) == 1 ) {
        $Result{ID} = $Response->{User}->[0]->{UserID};
      }
    }

   return %Result;
}



sub _KIXAPIUpdateUser {

  my %Params = %{$_[0]};
  my $Result = 0;

  $Params{User}->{ValidID} = $Params{User}->{ValidID} || 1;

  my $RequestBody = {
    "User" => {
        %{$Params{User}}
    }
  };

  $Params{Client}->PATCH(
      "/api/v1/system/users/".$Params{User}->{ID},
      encode("utf-8",to_json( $RequestBody ))
  );

  #  update ok...
  if( $Params{Client}->responseCode() eq "200") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{UserID};
  }
  else {
    print STDERR "Updating user failed (Response ".$Params{Client}->responseCode().")!";
    print STDERR "\ndata submitted: ".Dumper($RequestBody)."\n";

  }

  return $Result;

}



sub _KIXAPICreateUser {

  my %Params = %{$_[0]};
  my $Result = 0;

  $Params{User}->{ValidID} = $Params{User}->{ValidID} || 1;

  my $RequestBody = {
    "User" => {
        %{$Params{User}}
    }
  };
  $Params{Client}->POST(
      "/api/v1/system/users",
      encode("utf-8", to_json( $RequestBody ))
  );

  if( $Params{Client}->responseCode() ne "201") {
    print STDERR "\nCreating user failed (Response ".$Params{Client}->responseCode().")!";
    print STDERR "\ndata submitted: ".Dumper($RequestBody)."\n";

    $Result = 0;
  }
  else {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{UserID};
  }

  return $Result;

}



#-------------------------------------------------------------------------------
# ASSET HANDLING FUNCTIONS KIX-API
sub _KIXXAPISearchAsset {

    my %Params = %{$_[0]};
    my %Result = (
       ID => 0,
       Msg => ''
    );
    my $Client = $Params{Client};

    my @ResultItemData = qw{};
    my @Conditions = qw{};

    my $IdentAttr  = $Params{Identifier} || "";
    my $IdentStrg  = $Params{SearchValue} || "";

    print STDOUT "Search asset by Number EQ '$IdentStrg' or "
      ." <$IdentAttr> EQ '$IdentStrg'"
      .".\n" if( $Config{Verbose} > 3);

    push( @Conditions,
      {
        "Field"    => "Number",
        "Operator" => "EQ",
        "Type"     => "STRING",
        "Value"    => $IdentStrg
      }
    );
    push( @Conditions,
      {
        "Field"    => $IdentAttr,
        "Operator" => "EQ",
        "Type"     => "STRING",
        "Value"    => $IdentStrg
      }
    );

    my $Query = {};
    $Query->{ConfigItem}->{OR} =\@Conditions;
    my @QueryParams = (
      "search=".uri_escape( to_json( $Query)),
    );
    my $QueryParamStr = join( ";", @QueryParams);

    $Params{Client}->GET( "/api/v1/cmdb/configitems?$QueryParamStr");

    if( $Client->responseCode() ne "200") {
      $Result{Msg} = "Search for asset failed (Response ".$Client->responseCode().")!";
    }
    else {

      my $Response = from_json( $Client->responseContent() );
      if( scalar(@{$Response->{ConfigItem}}) > 1 ) {
        $Result{Msg} = "More than on item found for identifier.";
      }
      elsif( scalar(@{$Response->{ConfigItem}}) == 1 ) {
        $Result{ID} = $Response->{ConfigItem}->[0]->{ConfigItemID};
      }
    }

   return %Result;
}



sub _KIXAPIUpdateAsset {

  my %Params = %{$_[0]};
  my $Result = 0;

  my $RequestBody = {
    "ConfigItemVersion" => {
      "DeplStateID" => $Params{Asset}->{DeplStateID},
      "InciStateID" => $Params{Asset}->{InciStateID},
      "Name"        => $Params{Asset}->{Name},
      "Data" => {

        # this is the part which is CI-class specific, e.g.
        "SectionGeneral" => {
          "ExternalInvNo" => $Params{Asset}->{ExtInvNumber},
          "Vendor"        => $Params{Asset}->{VendorName},
          "Model"         => $Params{Asset}->{ModelName},
        }
      }
    }
  };

  $Params{Client}->POST(
      "/api/v1/cmdb/configitems/".$Params{Asset}->{ID}."/versions",
      encode("utf-8", to_json( $RequestBody ))
  );

  # no update required...
  if( $Params{Client}->responseCode() eq "200") {
    $Result = 1
  }
  # new version added...
  elsif( $Params{Client}->responseCode() eq "201") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{VersionID};
  }
  else {
    print STDERR "Updating asset failed (Response ".$Params{Client}->responseCode().")!\n";
  }

  return $Result;

}



sub _KIXAPICreateAsset {

  my %Params = %{$_[0]};
  my $Result = 0;

  my $RequestBody = {
  	"ConfigItem" => {
      "ClassID" => $Params{Asset}->{AssetClassID},
      "Version" => {
        "DeplStateID" => $Params{Asset}->{DeplStateID},
        "InciStateID" => $Params{Asset}->{InciStateID},
        "Name"        => $Params{Asset}->{Name},
        "Data" => {
          # this is the part which is CI-class specific, e.g.
          "SectionGeneral" => {
            "ExternalInvNo" => $Params{Asset}->{ExtInvNumber},
            "Vendor"        => $Params{Asset}->{VendorName},
            "Model"         => $Params{Asset}->{ModelName},
          }
        }
      }
    }
  };

  $Params{Client}->POST(
      "/api/v1/cmdb/configitems",
      encode("utf-8", to_json( $RequestBody ))
  );

  if( $Params{Client}->responseCode() ne "201") {
    print STDERR "\nCreating asset failed (Response ".$Params{Client}->responseCode().")!\n";
    $Result = 0;
  }
  else {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{ConfigItemID};
  }

  return $Result;

}



sub _KIXAPIGeneralCatalogList {

  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};
  my $Class  = $Params{Class} || "-";
  my $Valid  = $Params{Valid} || "valid";

  my @Conditions = qw{};
  push( @Conditions,
    {
      "Field"    => "Class",
      "Operator" => "EQ",
      "Type"     => "STRING",
      "Value"    => $Class
    }
  );

  my $Query = {};
  $Query->{GeneralCatalogItem}->{AND} =\@Conditions;
  my @QueryParams = (
    "filter=".uri_escape( to_json( $Query)),
  );
  my $QueryParamStr = join( ";", @QueryParams);

  $Params{Client}->GET( "/api/v1/system/generalcatalog?$QueryParamStr");

  if( $Client->responseCode() ne "200") {
    print STDERR "\nSearch for GC class failed (Response ".$Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    for my $CurrItem ( @{$Response->{GeneralCatalogItem}}) {
      $Result{ $CurrItem->{Name} } = $CurrItem->{ItemID};
    }
  }

  return %Result;
}


#-------------------------------------------------------------------------------
# CONFIG/SETUP HANDLING FUNCTIONS KIX-API
sub _KIXAPIValidList {

  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};

  $Params{Client}->GET( "/api/v1/system/valid");

  if( $Client->responseCode() ne "200") {
    print STDERR "\nSearch for valid values failed (Response ".$Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    for my $CurrItem ( @{$Response->{Valid}}) {
      $Result{ $CurrItem->{Name} } = $CurrItem->{ID};
    }
  }

  return %Result;
}



sub _KIXAPICalendarList {

  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};

  for my $Index (1..99) {
    my $QueryParamStr = 'TimeZone::Calendar'.$Index.'Name';
    $Params{Client}->GET( "/api/v1/system/config/$QueryParamStr");

    if( $Client->responseCode() ne "200") {
      last;
    }
    else {
      my $Response = from_json( $Client->responseContent() );
      my $CurrItem = $Response->{SysConfigOption};
      $Result{ $CurrItem->{Value} } = $Index;
    }
  }
  return %Result;
}



sub _KIXAPIDynamicFieldList {

  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};
  my $Class  = $Params{ObjectType} || "-";

  my @Conditions = qw{};
  if( $Params{ObjectType} ) {
    push( @Conditions,
      {
        "Field"    => "ObjectType",
        "Operator" => "EQ",
        "Type"     => "STRING",
        "Value"    => $Params{ObjectType},
      }
    );
  }

  my $Query = {};
  my $QueryParamStr = "";

  if( @Conditions ) {
    $Query->{DynamicField}->{AND} =\@Conditions;
    my @QueryParams = (
      "filter=".uri_escape( to_json( $Query)),
      "include=Config"
    );
    $QueryParamStr = join( ";", @QueryParams);
  }

  $Params{Client}->GET( "/api/v1/system/dynamicfields?$QueryParamStr");

  if( $Client->responseCode() ne "200") {
    print STDERR "\nSearch for DF failed (Response ".$Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    for my $CurrItem ( @{$Response->{DynamicField}}) {
      $Result{ $CurrItem->{Name} } = {
        ID         => $CurrItem->{ID},
        FieldType  => $CurrItem->{FieldType},
        ObjectType => $CurrItem->{ObjectType},
        Config     => $CurrItem->{Config},
      };
    }
  }

  return %Result;
}



#-------------------------------------------------------------------------------
# FILE HANDLING FUNCTIONS

sub _ReadSources {
  my %Params = %{$_[0]};
  my %Result = ();


  # prepare CSV parsing...
  if( $Params{CSVSeparator} =~ /^tab.*/i) {
    $Params{CSVSeparator} = "\t";
  }
  if( $Params{CSVQuote} =~ /^none.*/i) {
    $Params{CSVQuote} = undef;
  }
  my $InCSV = Text::CSV->new (
    {
      binary => 1,
      auto_diag => 1,
      sep_char   => $Params{CSVSeparator},
      quote_char => $Params{CSVQuote},
      # new-line-handling may be modified TO DO
      #eol => "\r\n",
    }
  );


  #find relevant import files....
  my @ImportFiles = qw{};

  if( $Params{CSVInputFile} ) {
      push(@ImportFiles, $Params{CSVInputFile});
  }
  # read file pattern depending on import object type...
  else {
    opendir( DIR, $Params{CSVInputDir} ) or die $!;
    while ( my $File = readdir(DIR) || '' ) {

    	next if ( $File =~ m/^\./ );

      if( $Params{ObjectType} eq 'Asset' ) {
        next if ( $File !~ m/(.*)Asset(.+)\.csv$/ );
      }
      elsif( $Params{ObjectType} eq 'Contact' ) {
        next if ( $File !~ m/(.*)Contact(.+)\.csv$/ );
      }
      elsif( $Params{ObjectType} eq 'Organisation' ) {
        next if ( $File !~ m/(.*)Org(.+)\.csv$/ );
      }
      elsif( $Params{ObjectType} eq 'SLA' ) {
        next if ( $File !~ m/(.*)SLA(.+)\.csv$/ );
      }
      else {
        next;
      }
      next if ( $File =~ m/\.Result\./ );
      print STDOUT "\tFound import file $File".".\n" if( $Config{Verbose} > 1);
      push( @ImportFiles, $File);

    }
    closedir(DIR);
  }



  # import CSV-files to arrays...
  for my $CurrFile ( sort(@ImportFiles) ) {
    my $CurrFileName = $Config{CSVInputDir}."/".$CurrFile;
    my @ResultItemData = qw{};

    open my $FH, "<:encoding(".$Params{CSVEncoding}.")", $CurrFileName  or die "Could not read $CurrFileName: $!";

    $Result{"$CurrFile"} = $InCSV->getline_all ($FH);
    print STDOUT "Reading import file $CurrFileName".".\n" if( $Config{Verbose} > 2);

    close $FH;

  }

  print STDOUT "Read ".(scalar(keys(%Result)) )." import files.\n" if( $Config{Verbose} );


  return \%Result;
}


sub _WriteResult {
  my %Params = %{$_[0]};
  my $Result = 0;


  if( $Params{CSVSeparator} =~ /^tab.*/i) {
    $Params{CSVSeparator} = "\t";
  }
  if( $Params{CSVQuote} =~ /^none.*/i) {
    $Params{CSVQuote} = undef;
  }
  my $OutCSV = Text::CSV->new (
    {
      binary => 1,
      auto_diag => 1,
      sep_char   => $Params{CSVSeparator},
      quote_char => $Params{CSVQuote},
      eol => "\r\n",
    }
  );

  for my $CurrFile ( keys( %{$Params{Data}}) ) {

    my $ResultFileName = $CurrFile;
    $ResultFileName =~ s/\.csv/\.Result\.csv/g;
    my $OutputFileName = $Params{CSVOutputDir}."/".$ResultFileName;

    open ( my $FH, ">:encoding(".$Params{CSVEncoding}.")",
      $OutputFileName) or die "Could not write $OutputFileName: $!";

    for my $CurrLine ( @{$Params{Data}->{$CurrFile}} ) {
      $OutCSV->print ($FH, $CurrLine );
    }

    print STDOUT "\nWriting import result to <$OutputFileName>.";
    close $FH or die "Error while writing $Params{CSVOutput}: $!";

    if( $Params{RemoveSourceFile} ) {
      unlink( $Params{CSVInputDir}."/".$CurrFile );
    }

  }

}


1;
