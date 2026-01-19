#!/usr/bin/perl -w
# --
# bin/kix18.CSVSync.pl - imports CSV data into KIX18
# Copyright (C) 2006-2025 KIX Service Software GmbH, https://kixdesk.com
#
# written/edited by:
# * Torsten(dot)Thau(at)kixdesk(dot)com
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
use Pod::Usage;
use Data::Dumper;

use KIX18API;


# VERSION
=head1 SYNOPSIS

This script retrieves import selected business object data into a KIX18 by communicating with its REST-API

Use kix18.CSVSync.pl  --ot ObjectType* --help [other options]


=head1 OPTIONS

=over

=item
--ot: ObjectType  (Contact|Organisation|SLA|User)
=cut

=item
--ac: AssetClass  (e.g. Computer|Location|Software)
=cut

=item
--uam: use asset mapping defined in config file, rather than CSV headline
=cut

=item
--anl: attempt name lookup if no asset number if given and use first found asset as update destination
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
  "ac=s"       => \$Config{AssetClass},
  "anl"        => \$Config{AssetNameLookup},
  "uam"        => \$Config{UseAssetMapping},
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

# APOLOGY
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
my $KIXClient = KIX18API::Connect( %Config  );
exit(-1) if !$KIXClient;


# lookup validities...
my %ValidList = KIX18API::ValidList(
  { %Config, Client => $KIXClient}
);
my %RevValidList = reverse(%ValidList);



my $Result = 0;

# import CSV-data...
my $ResultData = $CSVDataRef;

#-------------------------------------------------------------------------------
# import Asset Data...
if ( $Config{ObjectType} eq 'Asset') {

  if ( !$Config{AssetClass} ) {
    print STDERR "\nAsset import requires asset class parameter - aborting.\n\n";
    pod2usage( -verbose => 1);
    exit(-1);
  }

  # lookup asset classes...
  my %AssetClassList = KIX18API::GeneralCatalogList(
    { %Config, Client => $KIXClient, Class => 'ITSM::ConfigItem::Class'}
  );

  $Config{AssetClassID} = $AssetClassList{ $Config{AssetClass} } || '';
  if ( !$Config{AssetClassID} ) {
    print STDERR "\nGiven asset class cannot be founde - aborting.\n\n";
    exit(-1);
  }

  # lookup deployment states...
  my %DeplStateList = KIX18API::GeneralCatalogList(
    { %Config, Client => $KIXClient, Class => 'ITSM::ConfigItem::DeploymentState'}
  );

  # lookup incident states...
  my %InciStateList = KIX18API::GeneralCatalogList(
    { %Config, Client => $KIXClient, Class => 'ITSM::Core::IncidentState'}
  );

  my %AssetClassDef = KIX18API::GetAssetClass({
    %Config,  Client => $KIXClient,
  });

  # get most recent asset class definition..
  my $NewestDef = ();
  my @SortedDefs = sort { $b->{'DefinitionID'} <=> $a->{'DefinitionID'} } @{$AssetClassDef{'Data'}->{'definitions'}};
  delete( $NewestDef->{'DefinitionString'});
  $NewestDef = $SortedDefs[0]->{'Definition'};


  my %KeyIndex = ();
  # get array index from mapping configuration...
  if( $Config{UseAssetMapping} ) {
    my $RowCount = 0;
    for my $CurrKey( keys(%Config) ) {
      next if( $CurrKey !~ /Asset\.ColIndex\.(.+)$/);
      $KeyIndex{ $1 } = $Config{$CurrKey};
      $RowCount++;
    }
    print STDOUT "\nusing predefined asset mapping for "
      . $RowCount
      ." rows."
      if( $Config{Verbose} > 4);
  }

  # process import lines
  FILE:
  for my $CurrFile ( keys( %{$CSVDataRef}) ) {
    my $LineCount = 0;

    if ( !$Config{UseAssetMapping}) {
      %KeyIndex = ();
    }

    LINE:
    for my $CurrLine ( @{$CSVDataRef->{$CurrFile}} ) {

      # get array index for each given attribute key...
      my %Asset = ();
      if ( !$Config{UseAssetMapping} && $LineCount < 1) {
        my $RowIndex = 0;
        for my $CurrKey( @{$CurrLine} ) {
          $KeyIndex{ $CurrKey } = $RowIndex;
          $RowIndex++;
        }
        print STDOUT "\nusing CSV defined asset mapping for "
          . $RowIndex
          ." rows."
          if( $Config{Verbose} > 4);

        $LineCount++;
        next LINE;
      }


      # build new asset and version hash from CSV data...
      $Asset{'ClassID'} = $Config{AssetClassID} || '';

      my $DataIndex = $KeyIndex{'Number'};
      $Asset{'Number'} = $CurrLine->[$DataIndex] || '';

      my %VersionData = ();

      $DataIndex = $KeyIndex{'Name'};
      $Asset{'Version'}->{'Name'} = $CurrLine->[$DataIndex];

      $DataIndex = $KeyIndex{'Deployment State'};
      my $ImportValue = "";
      if( $DataIndex =~/^SET\:(.+)/) {
        $ImportValue = $1 || "Production";
      }
      else {
        $ImportValue = $CurrLine->[$DataIndex]
      }
      $Asset{'Version'}->{'DeplStateID'} = $DeplStateList{$ImportValue};

      $DataIndex = $KeyIndex{'Incident State'};
      $ImportValue = "";
      if( $DataIndex =~/^SET\:(.+)/) {
        $ImportValue = $1 || "Operational";
      }
      else {
        $ImportValue = $CurrLine->[$DataIndex]
      }
      $Asset{'Version'}->{'InciStateID'} = $InciStateList{$ImportValue};

      $Asset{'Version'}->{'Data'} = _BuildAssetVersionData(
          Definition => $NewestDef,
          Data       => $Asset{'Version'},
          KeyIndex   => \%KeyIndex,
          DataArray  => $CurrLine,
      );


      # search asset for possible update...
      my $UpdateAssetID = 0;
      if( $Asset{'Number'} ) {
          my %SearchResult = KIX18API::SearchAsset({
            %Config,
            Client      => $KIXClient,
            SearchValue => $Asset{Number} || ''
          });

          # handle errors...
          if ( $SearchResult{Msg} ) {
            push( @{$CurrLine}, 'ERROR');
            push( @{$CurrLine}, $SearchResult{Msg});
          }
          elsif ( $SearchResult{ID} ) {
              $UpdateAssetID = $SearchResult{ID};
          }
      }
      elsif( $Config{AssetNameLookup} ) {

        my %SearchResult = KIX18API::SearchAsset({
          %Config,
          Client      => $KIXClient,
          Identifier  => "Name" || '',
          SearchValue => $Asset{'Version'}->{'Name'} || ''
        });

        # handle errors...
        if ( $SearchResult{Msg} ) {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, $SearchResult{Msg});
        }
        elsif ( $SearchResult{ID} ) {
            $UpdateAssetID = $SearchResult{ID};
        }
      }

      # update existing asset...
      if( $UpdateAssetID ) {

        $Asset{ID} = $UpdateAssetID;
        my $AssetID = KIX18API::UpdateAsset(
          { %Config, Client => $KIXClient, Asset => \%Asset }
        );

        if ( $AssetID == 1 ) {
          push( @{$CurrLine}, 'no update required');
          push( @{$CurrLine}, '');
        }
        else {
          push( @{$CurrLine}, 'update');
          push( @{$CurrLine}, '');
        }

        print STDOUT "$LineCount: Updated asset <$AssetID> for <"
          . $Asset{Number}
          . ">.\n"
          if( $Config{Verbose} > 2);
     }
     # create new asset...
     else {
        my $NewAssetID = KIX18API::CreateAsset(
          { %Config, Client => $KIXClient, Asset => \%Asset }
        ) || '';

        if ( $NewAssetID ) {
          push( @{$CurrLine}, 'created');
          push( @{$CurrLine}, 'AssetID: '.$NewAssetID);
        }
        else {
          push( @{$CurrLine}, 'ERROR');
          push( @{$CurrLine}, 'Create failed.');
        }

        print STDOUT "\nCSV line $LineCount: Created asset <$NewAssetID> for <"
          .($Asset{'Version'}->{'Name'} || '')
          . ">.\n"
          if( $Config{Verbose} > 2);
      }

      $LineCount++;

    }# next LINE;

  }# next FILE;


}
elsif ( $Config{ObjectType} eq 'SLA') {

  my %CalendarList = KIX18API::CalendarList(
    { %Config, Client => $KIXClient }
  );

  # there is no SLA-search method, so we jsut get all SLAs now...
  my %SLAList = KIX18API::ListSLA(
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
        my $Result = KIX18API::UpdateSLA(
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
        my $NewSLAID = KIX18API::CreateSLA(
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
elsif ( $Config{ObjectType} eq 'Contact' || $Config{ObjectType} eq 'User') {

  my %OrgIDCache = ();

  # lookup DFs for organizations...
  my %DFList = KIX18API::DynamicFieldList(
    { %Config, Client => $KIXClient, ObjectType => 'Contact'}
  );
  my %IgnoredDF = ();

  # lookup permission roles...
  my %RoleList = KIX18API::RoleList(
    { %Config, Client => $KIXClient}
  );

  # check for givven identifier attribute..
  if( $Config{'Contact.IdentifierAttribute'} && ($Config{'Contact.IdentifierAttribute'} eq 'UserLogin' || $Config{'Contact.IdentifierAttribute'} eq 'Email' )) {
    $Config{Identifier} = $Config{'Contact.IdentifierAttribute'};
  }
  else {
    $Config{Identifier} = 'Email';
    print STDOUT "Contact import: no valid identifier attribute given ('UserLogin'|'Email') - assuming 'Email'.\n";
  }

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
          my @RoleArr = ();
          if ($Config{'Contact.ColIndex.Roles'} && $CurrLine->[$Config{'Contact.ColIndex.Roles'}]) {
            my $RolesStrg = $CurrLine->[$Config{'Contact.ColIndex.Roles'}];
            utf8::encode($RolesStrg);
            @RoleArr = split( /\s*,\s*/, $RolesStrg );
          }

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
          if( $Config{'Contact.AutoAddContextRoles'} ) {
            push( @RoleArr, 'Agent User') if( $IsAgent );
            push( @RoleArr, 'Customer') if( $IsCustomer );
          }

          # get role ids for user...
          my @RoleIDsArr = qw{};
          ROLENAME:
          for my $CurrRoleName ( @RoleArr ) {
              next ROLENAME if( !$RoleList{$CurrRoleName});
              next ROLENAME if( !$RoleList{$CurrRoleName}->{ID} );

              if(  ($RoleList{$CurrRoleName}->{Customer} && $IsCustomer)
                || ($RoleList{$CurrRoleName}->{Agent} && $IsAgent))
              {
                push( @RoleIDsArr, $RoleList{$CurrRoleName}->{ID} ) ;
              }

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
          my $UserPw = undef;
          if ($Config{'Contact.ColIndex.Password'} && $CurrLine->[$Config{'Contact.ColIndex.Password'}]) {
            $UserPw = $CurrLine->[$Config{'Contact.ColIndex.Password'}];
          }

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
          my %SearchResult = KIX18API::SearchUser({
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
            my $UserID = KIX18API::UpdateUser(
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

            # only set UserPw if pw given (backend creates random pw then)
            if( $UserPw ) {
              $User{UserPw} = $UserPw;
            }

            my $NewUserID = KIX18API::CreateUser(
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

      if( $Config{ObjectType} eq 'User' ) {
        next;
      }

      # ------------------------------------------------------------------------
      # handle contact
      if( !$CurrLine->[$Config{'Contact.SearchColIndex'}] ) {
        push( @{$CurrLine}, 'ERROR');
        push( @{$CurrLine}, 'Identifier missing.');
        print STDOUT "$LineCount: identifier missing.\n";
        next;
      }


      # get all (other) organization numbers...
      my %AllOrgIDs = ();
      
      if( $Config{'Contact.ColIndex.OrgNumbers'} && $CurrLine->[$Config{'Contact.ColIndex.OrgNumbers'}] ) {
        my $AllOrgIDStrg = $CurrLine->[$Config{'Contact.ColIndex.OrgNumbers'}] || '';

        # split comma separated organisation numbers and look up each OrgID...
        for my $CurrOrgNo ( split(",", $AllOrgIDStrg ) ) {
          my $CurrOrgID = "";

          # check in cache for org-number...
          if( $OrgIDCache{ $CurrOrgNo } ) {
            $CurrOrgID = $OrgIDCache{ $CurrOrgNo };
          }
          # lookup org-number...
          else {

            my %OrgID = KIX18API::SearchOrg({
              %Config,
              Client      => $KIXClient,
              SearchValue => $CurrOrgNo || '-',
            });

            if ( $OrgID{ID} ) {
              $CurrOrgID = $OrgID{ID};
              $OrgIDCache{ $CurrOrgNo } = $CurrOrgID;
            }
            else {
              print STDOUT "$LineCount: no organization found for <"
                . $CurrOrgNo
                . ">.\n"
            }
          }

          # remember org-id for this org-number...
          if( $CurrOrgID ) {
            $AllOrgIDs{$CurrOrgID} = 1;
          }
        }

      }

      # check primary org id...
      # NOTE: we do NOT check if primary org is contained in all org list,
      # rather it is added automatically to this list.
      my $OrgID = undef;
      if( $OrgIDCache{ $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}] } ) {
        $OrgID = $OrgIDCache{ $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}] };

      }
      elsif( $CurrLine->[$Config{'Contact.ColIndex.PrimaryOrgNo'}] ) {

        my %OrgID = KIX18API::SearchOrg({
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

      
      # get fixed contact attributes..
      my %Contact = (
          City            => $CurrLine->[$Config{'Contact.ColIndex.City'}],
          Comment         => $CurrLine->[$Config{'Contact.ColIndex.Comment'}],
          Country         => $CurrLine->[$Config{'Contact.ColIndex.Country'}],
          Email           => $CurrLine->[$Config{'Contact.ColIndex.Email'}],
          Email1          => $CurrLine->[$Config{'Contact.ColIndex.Email1'}],
          Email2          => $CurrLine->[$Config{'Contact.ColIndex.Email2'}],
          Email3          => $CurrLine->[$Config{'Contact.ColIndex.Email3'}],
          Email4          => $CurrLine->[$Config{'Contact.ColIndex.Email4'}],
          Email5          => $CurrLine->[$Config{'Contact.ColIndex.Email5'}],
          Fax             => $CurrLine->[$Config{'Contact.ColIndex.Fax'}],
          Firstname       => $CurrLine->[$Config{'Contact.ColIndex.Firstname'}],
          Lastname        => $CurrLine->[$Config{'Contact.ColIndex.Lastname'}],
          Login           => $CurrLine->[$Config{'Contact.ColIndex.Login'}],
          Mobile          => $CurrLine->[$Config{'Contact.ColIndex.Mobile'}],
          Phone           => $CurrLine->[$Config{'Contact.ColIndex.Phone'}],
          Street          => $CurrLine->[$Config{'Contact.ColIndex.Street'}],
          Title           => $CurrLine->[$Config{'Contact.ColIndex.Title'}],
          ValidID         => $ContactValidId,
      );
      
      # get optional contact attributes..
      my @ContactDefaultFields = qw( City Comment Country Email Fax Firstname Lastname Login Mobile Phone Street Title Zip );
      for my $ContactElement (@ContactDefaultFields) {
        if ($Config{'Contact.ColIndex.'.$ContactElement} && $CurrLine->[$Config{'Contact.ColIndex.'.$ContactElement}]) {
          $Contact{$ContactElement} = $CurrLine->[$Config{'Contact.ColIndex.'.$ContactElement}]
        }
      }

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
        # always add PrimaryOrg to AllOrgIDs...
        $AllOrgIDs{$OrgID} = 1;
        my @OrgIDs = keys( %AllOrgIDs ) ;
        $Contact{OrganisationIDs} = \@OrgIDs;
        $Contact{PrimaryOrganisationID} = $OrgID;
      }



      # search contact...
      my %SearchResult = KIX18API::SearchContact({
        %Config,
        Client      => $KIXClient,
        SearchValue => $CurrLine->[$Config{'Contact.SearchColIndex'}] || '-'
      });

      # handle errors...
      if ( $SearchResult{Msg} ) {
        push( @{$CurrLine}, 'ERROR');
        push( @{$CurrLine}, $SearchResult{Msg});
        print STDOUT "$LineCount: Search for contact failed <$CurrLine->[$Config{'Contact.SearchColIndex'}]> - $SearchResult{Msg}.\n";
      }

      # update existing $Contact...
      elsif ( $SearchResult{ID} ) {
        $Contact{ID} = $SearchResult{ID};
        my $ContactID = KIX18API::UpdateContact(
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

        my $NewContactID = KIX18API::CreateContact(
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
  my %DFList = KIX18API::DynamicFieldList(
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
          Number   => $CurrLine->[$Config{'Org.ColIndex.Number'}],
          ValidID  => $ValidId,
      );
      
      # get optional organization attributes..
      my @OrganizationDefaultFields = qw( City Name Comment Street City Zip Country Url );
      for my $OrganizationElement (@OrganizationDefaultFields) {
        if ($Config{'Org.ColIndex.'.$OrganizationElement} && $CurrLine->[$Config{'Org.ColIndex.'.$OrganizationElement}]) {
          $Organization{$OrganizationElement} = $CurrLine->[$Config{'Org.ColIndex.'.$OrganizationElement}];
        }
      }

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
      my %SearchResult = KIX18API::SearchOrg({
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
        my $OrgID = KIX18API::UpdateOrg(
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

        my $NewOrgID = KIX18API::CreateOrg(
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
elsif ( $Config{ObjectType} eq 'Queue') {

  my %CalendarList = KIX18API::CalendarList(
      { %Config, Client => $KIXClient }
  );

  my %SystemAddressList = KIX18API::ListSystemAddress(
      { %Config, Client => $KIXClient }
  );

  # there is no SLA-search method, so we jsut get all SLAs now...
  my %QueueList = KIX18API::ListQueue(
      { %Config, Client => $KIXClient }
  );

  # process import lines
  FILE:
  for my $CurrFile (keys(%{$CSVDataRef})) {

    my $LineCount = 0;

    LINE:
    for my $CurrLine (@{$CSVDataRef->{$CurrFile}}) {

      # skip first line (ignore header)...
      if ($LineCount < 1) {
        $LineCount++;
        next;
      }

      # prepare validity..
      my $QueueValidId = 1;
      if ($Config{'Queue.ColIndex.ValidID'} =~ /^SET\:(.+)/) {
        $QueueValidId = $1;
      }
      else {
        $QueueValidId = $CurrLine->[$Config{'Queue.ColIndex.ValidID'}];
      }
      if ($QueueValidId !~ /^\d+$/ && $RevValidList{ $QueueValidId }) {
        $QueueValidId = $RevValidList{ $QueueValidId } || '';
      }
      else {
        $QueueValidId = "";
      };

      # create Queue data hash/map from CSV data...
      my %Queue = (
          Name            => ($CurrLine->[$Config{'Queue.ColIndex.FullQueueName'}] || ''),
          Calendar        => ($CurrLine->[$Config{'Queue.ColIndex.Calendar'}] || ''),
          FollowUpID      => ($CurrLine->[$Config{'Queue.ColIndex.FollowUpID'}] || ''),
          SystemAddressID => ($CurrLine->[$Config{'Queue.ColIndex.SystemAddress'}] || ''),
          UnlockTimeOut   => ($CurrLine->[$Config{'Queue.ColIndex.UnlockTimeOut'}] || ''),
          Comment         => ($CurrLine->[$Config{'Queue.ColIndex.Comment'}] || ''),
          ValidID         => $QueueValidId,
      );

      # replace calendar name by calendar index...
      $Queue{Calendar} = $CalendarList{$Queue{Calendar}} || '';
      # splitt Queue in Array by sperator ::
      my @Queues =  split('::', $Queue{Name});

      #count Entry of Array
      my $QueueEntrys = scalar(@Queues);

      if ($QueueEntrys > 1 ) {

        # save Queue-Name
        my $QueueName = $Queues[-1];

        #set Queue-Name
        $Queue{Name} = $QueueName;

        # extract parent queue
        pop(@Queues);
        my  $ParentQueue = join( "::", @Queues);

        # cleanup empty values...
        for my $CurrKey (keys(%Queue)) {
          $Queue{$CurrKey} = undef if (!length($Queue{$CurrKey}));
        }

        # resolve ParentQueueID by Queue Name
        my $ParentQueueID = KIX18API::QueueValueLookup({
            %Config,
            Client => $KIXClient,
            Name   => $ParentQueue
        }) || '';

        # replace QueueName with ID
        $Queue{ParentID} = $ParentQueueID;

      } else {

        # save Queue-Name
        my $QueueName = $Queues[-1];
        #set Queue-Name
        $Queue{Name} = $QueueName;
      }

      # get SystemID by Name
      # use lower case fpr email addresses..
      $Queue{SystemAddressID} = lc($Queue{SystemAddressID});
      my $SystemAddressID = KIX18API::SystemAddressValueLookup({
          %Config,
          Client => $KIXClient,
          Name   => $Queue{SystemAddressID}
      }) || '';

      # set SystemAddress
      if ($SystemAddressID) {
        # replace SystemAddress Name by id
        $Queue{SystemAddressID} = $SystemAddressID || '';
      }
      else {

        # build Hash
        my %SystemAddress = (
            Name     => $Queue{SystemAddressID},
            Realname => => $Queue{SystemAddressID},
            ValidID  => => 1
        );

        # create Systemaddress
        my $NewSystemAddressID = KIX18API::CreateSystemAddress(
            { %Config, Client => $KIXClient, SystemAddress => \%SystemAddress }
        );

        if ($NewSystemAddressID) {
          push(@{$CurrLine}, 'created');
          push(@{$CurrLine}, $NewSystemAddressID);
        }
        else {
          push(@{$CurrLine}, 'ERROR');
          push(@{$CurrLine}, 'Create failed.');
        }

        $Queue{SystemAddressID} = $NewSystemAddressID || '';

        print STDOUT "$LineCount: Created Queue <$NewSystemAddressID / "
            . $Queue{Name} . ">.\n"
            if ($Config{Verbose} > 2);
      }

      # update existing Queue...
      if ($QueueList{ $CurrLine->[$Config{'Queue.ColIndex.FullQueueName'}]}) {

        my %QueueData = %{$QueueList{ $CurrLine->[$Config{'Queue.ColIndex.FullQueueName'}]}};

        $Queue{ID} = $QueueData{ID};

        my $Result = KIX18API::UpdateQueue(
            { %Config, Client => $KIXClient, Queue => \%Queue }
        );

        if (!$Result) {
          push(@{$CurrLine}, 'ERROR');
          push(@{$CurrLine}, 'Update failed.');
        }
        elsif ($Result == 1) {
          push(@{$CurrLine}, 'no update required');
          push(@{$CurrLine}, $Queue{ID});
        }
        else {
          push(@{$CurrLine}, 'update');
          push(@{$CurrLine}, $Queue{ID});
        }

        print STDOUT "$LineCount: Updated Queue <" . $Queue{ID} . " / "
            . $Queue{Name}
            . ">.\n"
            if ($Config{Verbose} > 2);

      }
      # create new Queue...
      else {
        my $NewQueueID = KIX18API::CreateQueue(
            { %Config, Client => $KIXClient, Queue => \%Queue }
        );

        if ($NewQueueID) {
          push(@{$CurrLine}, 'created');
          push(@{$CurrLine}, $NewQueueID);
        }
        else {
          push(@{$CurrLine}, 'ERROR');
          push(@{$CurrLine}, 'Create failed.');
        }

        print STDOUT "$LineCount: Created Queue <$NewQueueID / "
            . $Queue{Name} . ">.\n"
            if ($Config{Verbose} > 2);
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





#-------------------------------------------------------------------------------
# ASSET DATA HANDLING FUNCTIONS
sub _BuildAssetVersionData {
    my ( %Param ) = @_;
    return if !$Param{Definition};
    return if ref $Param{Definition} ne 'ARRAY';
    return if !$Param{KeyIndex};
    return if ref $Param{KeyIndex} ne 'HASH';
    return if !$Param{DataArray};
    return if ref $Param{DataArray} ne 'ARRAY';
    my %Result = ();

    $Param{KeyPrefix} = $Param{KeyPrefix} || '';

    ITEM:
    for my $Item ( @{ $Param{Definition} } ) {

        my $IsArray = defined( $Item->{CountMin}) || defined($Item->{CountMax});
        my $IsHash = defined($Item->{Sub});
        my $CountMax = $Item->{CountMax} || 1;

        $Result{$Item->{Key}} = undef;

        COUNT:
        for my $Count ( 1 .. $CountMax ) {

            # create key string
            my $Key = $Item->{Key} . '::' . $Count;
            if ( $Param{KeyPrefix} ) {
                $Key = $Param{KeyPrefix} . '::' . $Key;
            }

            # get CSV array index for key...
            my $DataIndex = $Param{KeyIndex}->{$Key};
            if( !$DataIndex ) {
              $DataIndex = $Param{KeyIndex}->{ $Param{KeyPrefix} . '::'. $Item->{Key}};
            }

            # get data from CSV line...
            my $Value = '';
            if( $DataIndex && $Param{DataArray}->[$DataIndex] ) {
              $Value = $Param{DataArray}->[$DataIndex];
            }

            # lookup values for specific attribute types...
            if( $Value && $Item->{Input}->{Type}
              && $Item->{Input}->{Type} !~ /^Text/
              && $Config{Verbose} > 4)
            {
              print STDOUT "\nLookup value <$Value> for key <$Item->{Key}> of "
                ."type <$Item->{Input}->{Type}>. ";
            }
            if( $Value && $Item->{Input}->{Type} eq 'Organisation') {

              my %SearchResult = KIX18API::SearchOrg({
                %Config, Client => $KIXClient, SearchValue => $Value,
              });
              if ( $SearchResult{ID} ) {
                $Value = $SearchResult{ID};
                print STDOUT " => using <$Value>" if ($Config{Verbose} > 4);
              }

            }
            elsif( $Value && $Item->{Input}->{Type} eq 'Contact') {

              my %SearchResult = KIX18API::SearchContact({
                %Config, Client => $KIXClient, SearchValue => $Value
              });
              if ( $SearchResult{ID} ) {
                $Value = $SearchResult{ID};
                print STDOUT " => using <$Value>" if ($Config{Verbose} > 4);
              }

            }
            elsif( $Value && $Item->{Input}->{Type} eq 'GeneralCatalog') {

              $Value = KIX18API::GeneralCatalogValueLookup({
                %Config,
                Client => $KIXClient,
                Class => $Item->{Input}->{Class},
                Value => $Value
              }) || $Value;
              print STDOUT " => using <$Value>" if ($Config{Verbose} > 4);

            }
            elsif( $Value && $Item->{Input}->{Type} eq 'CIClassReference') {

              my %SearchResult = KIX18API::SearchAsset({
                %Config,
                Client      => $KIXClient,
                Identifier  => "Name",
                SearchValue => "$Value",
              });
              if ( $SearchResult{ID} && !$Result{Msg} ) {
                  $Value = $SearchResult{ID};
                  print STDOUT " => using <$Value>" if ($Config{Verbose} > 4);
              }

            }
            elsif( $Value && $Item->{Input}->{Type} eq 'SLAReference') {

              $Value = KIX18API::SLAValueLookup({
                %Config,
                Client => $KIXClient,
                Name   => $Value
              }) || $Value;
              print STDOUT " => using <$Value>" if ($Config{Verbose} > 4);

            }

            my %SubData = ();
            if( $Item->{Sub} ) {
              my $SubDefRef = $Item->{Sub};

              %SubData = %{_BuildAssetVersionData(
                  %Param,
                  Definition => $SubDefRef,
                  KeyPrefix  => $Key,
              )};
            }

            # ignore/drop empty values...
            if( $IsArray && $IsHash && keys(%SubData)) {
              if( $Value ) {
                $SubData{$Item->{Key}} = $Value;
              }
              $Result{$Item->{Key}}->[$Count-1] = \%SubData;

            }
            elsif( $IsArray && $Value) {
              $Result{$Item->{Key}}->[$Count-1] = $Value;
            }
            elsif( $IsHash && keys(%SubData)) {
              $Result{$Item->{Key}} = \%SubData;
            }
            elsif( $Value ) {
              $Result{$Item->{Key}} = $Value;
            }
        }

        # drop empty values...
        delete( $Result{$Item->{Key}} ) if (!$Result{$Item->{Key}});
    }


    return \%Result;
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

  my $EOL = undef;
  if( $Params{CSVEOL} && $Params{CSVEOL} ne 'no' ) {
    $EOL = $Params{CSVEOL};
  }
  # get OS from Hostsystem
  my $OS = $^O;

  # if host system macOS set EOL undef
  if ($OS eq 'darwin') {
    $EOL = undef;
  }

  my $InCSV = Text::CSV->new (
    {
      binary => 1,
      auto_diag => 1,
      sep_char   => $Params{CSVSeparator},
      quote_char => $Params{CSVQuote},
      eol => $EOL,
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

  my $EOL = "\r\n";

  # get OS from Hostsystem
  my $OS = $^O;

  # if Hostsystem MacOS set EOL undef
  if ($OS eq 'darwin') {
      $EOL = undef;
  }

  my $OutCSV = Text::CSV->new (
    {
      binary => 1,
      auto_diag => 1,
      sep_char   => $Params{CSVSeparator},
      quote_char => $Params{CSVQuote},
      eol => $EOL,
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
