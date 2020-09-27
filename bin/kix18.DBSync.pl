#!/usr/bin/perl -w
# --
# bin/kix18.DBSync.pl - imports DB data into KIX18
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

This script retrieves ticket- and asset information from a KIX18 by communicating with its REST-API. Information is stored locally in database tables.

Use ./bin/kix18.DBSync.pl --config ./config/kix18.DBSync.cfg --ot Contact|Organisation --help [other options]


=head1 OPTIONS

=over

=item
--config: path to configuration file instead of command line params
=cut

=item
--ot: object to be imported (Contact|Organisation)
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
--du: DBUser  (if not given by config)
=cut

=item
--dp: DBPassword (if not given by config)
=cut

=item
--verbose: makes the script verbose
=cut

=item
--help show help message
=cut

=item
--orgsearch enables org.-lookup by search (requires hotfix in KIX18-backend!)
=cut

=back


=head1 REQUIREMENTS

The script has been developed using CentOS8 or Ubuntu/Debian as target plattform. Following packages must be installed:

=over

=item
shell> sudo yum install perl-Config-Simple perl-REST-Client perl-JSO perl-LWP-Protocol-https perl-DBI perl-URI perl-Pod-Usage perl-Getopt-Long
=cut

=item
shell> sudo apt install libconfig-simple-perl librest-client-perl libjson-perl liblwp-protocol-https-perl libdbi-perl liburi-perl perl-doc libgetopt-long-descriptive-perl perl-Text-CSV
=cut


=back

Depending on the DBMS to be connected, additional packages might be required, e.g.

=over

=item
shell> sudo yum install perl-DBD-Pg perl-DBD-MySQL perl-DBD-ODBC
=cut

=item
shell> sudo yum install libdbd-pg-perl libdbd-mysql-perl libdbd-odbc-perl
=cut

=back

=cut

my $Help           = 0;
my %Config         = ();
$Config{Verbose}         = 0;
$Config{ConfigFilePath}  = "";
$Config{KIXURL}          = "";
$Config{KIXUserName}     = "";
$Config{KIXPassword}     = "";
$Config{DBUser}          = "";
$Config{DBPassword}      = "";

# temporary workaround...
$Config{OrgSearch}       = "";

# read some params from command line...
GetOptions (
  "config=s"  => \$Config{ConfigFilePath},
  "url=s"     => \$Config{KIXURL},
  "u=s"       => \$Config{KIXUserName},
  "p=s"       => \$Config{KIXPassword},
  "ot=s"      => \$Config{ObjectType},
  "verbose=i" => \$Config{Verbose},
  # temporary workaround...
  "orgsearch" => \$Config{OrgSearch},
  "help"      => \$Help,
);

if( $Help ) {
  pod2usage( -verbose => 3);
  exit(-1)
}


# read config file...
my %FileConfig = ();
if( $Config{ConfigFilePath} ) {
    print STDOUT "\nReading config file $Config{ConfigFilePath} ..." if( $Config{Verbose});
    Config::Simple->import_from( $Config{ConfigFilePath}, \%FileConfig);

    for my $CurrKey ( keys( %FileConfig )) {
      my $LocalKey = $CurrKey;
      $LocalKey =~ s/(DB\.|KIXAPI.)//g;
      $Config{$LocalKey} = $FileConfig{$CurrKey} if(!$Config{$LocalKey});
    }

}

# check requried params...
for my $CurrKey (qw{ObjectType ConfigFilePath KIXURL KIXUserName KIXPassword DSN DBUser DBPassword}) {
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

# log into KIX-Backend API
my $KIXClient = _KIXAPIConnect( %Config  );
exit(-1) if !$KIXClient;



# connect do database...
my $DBHandle = _DBConnect( %Config );
exit(-1) if !$DBHandle;

my $OT = $Config{ObjectType};
my $Identifier = "";
$Identifier = "Email" if( $Config{ObjectType} eq 'Contact' );
$Identifier = "Number" if( $Config{ObjectType} eq 'Organisation' );

if ( !$Identifier ) {
  print STDERR "\nUnknown object type '$Config{ObjectType}' - aborting.\n\n";
  pod2usage( -verbose => 1);
  exit(-1)
}


# prepare attribute-2-column map...
my %Map = ();
my %FixValueMap = ();
KEY:
for my $CurrKey ( sort( keys(%Config) ) ) {
    next KEY if ($CurrKey eq $Config{ObjectType}.".Table");
    next KEY if ($CurrKey eq $Config{ObjectType}.".Condition");
    next KEY if ($CurrKey !~ /^$OT\.(.+)/);
    my $KeyName = $1;

    if( $Config{$CurrKey} =~ /^SET\:(.+)/) {
        $FixValueMap{$KeyName} = $1;
    }
    else {
        $Map{$KeyName} = $Config{$CurrKey};
    }
}

# prepare SQL query...
my @RowNames = values(%Map);
my %RevMap = reverse %Map;

my $SQL = "SELECT "
  . join( ", ", @RowNames)
  ." FROM "
  . $Config{ $Config{ObjectType}.'.Table' };

my $Condition = "";
if( $Config{ $Config{ObjectType}.".Condition" } ) {
    $Condition = " WHERE ".$Config{ $Config{ObjectType}.".Condition" };
}

my $Sort = " ORDER BY ".$Config{ $Config{ObjectType}.'.'.$Identifier };

my $Limit = "";
if( $Config{DBLimit} && $Config{DSN} =~/Pg|msysql/) {
    $Limit = " LIMIT ".$Config{DBLimit}
}

# query database...
my $Query = $DBHandle->prepare($SQL.$Condition.$Sort.$Limit);
my $QR = $Query->execute();

if( !$QR ) {
  print STDOUT "\nFailed to query $Config{ObjectType}: ".$Query->err_str;
}
else {
  my $LineCount = 0;

  # process each query result..
  DBITEM:
  while ( my @CurrLine = $Query->fetchrow_array() ) {

      $LineCount++;

      my %Data = ();
      my $RowIndex = 0;
      for my $CurrKey ( @RowNames ) {
        $Data{ $RevMap{$CurrKey} } = decode("utf-8", $CurrLine[$RowIndex]);
        $RowIndex++;
      }

      if( !$Data{$Identifier} ) {
        print STDOUT "$LineCount: identifier missing - skipping.\n";
        next DBITEM;
      }



      # search item...
      my %SearchResult = ();
      if ( $Config{ObjectType} eq 'Contact') {
          %SearchResult = _KIXAPISearchContact({
            %Config,
            Client      => $KIXClient,
            SearchValue => $Data{$Identifier},
          });
      }
      elsif( $Config{ObjectType} eq 'Organisation') {
          %SearchResult = _KIXAPISearchOrg({
            %Config,
            Client      => $KIXClient,
            SearchValue => $Data{$Identifier},
          });
      }
      if ( $SearchResult{Msg} ) {
        print STDOUT "$LineCount: ".$SearchResult{Msg}." - skipping\n";
        next DBITEM;
      }


      # prepare data
      if ( $Config{ObjectType} eq 'Contact') {
          # (1b) for contact get org.-id out of org.-number...
          $Data{PrimaryOrganisationID} = undef;
          $Data{OrganisationIDs} = undef;
          if( $Data{'PrimaryOrgNo'} ) {
              my %OrgID = _KIXAPISearchOrg({
                %Config,
                Client      => $KIXClient,
                SearchValue => $Data{'PrimaryOrgNo'},
              });

              if ( $OrgID{ID} ) {
                  $Data{PrimaryOrganisationID} = $OrgID{ID};
                  $Data{OrganisationIDs} = [$OrgID{ID}];
              }
              else {
                  print STDOUT "$LineCount: no organization found for <"
                    . $Data{'PrimaryOrgNo'}
                    . "> ($Data{'Email'}/$Data{'Login'}).\n";
            }
          }
      }
      elsif( $Config{ObjectType} eq 'Organisation') {
          # (1b) nothing to prepare yet...
      }

      # (2) fixed values
      for my $CurrKey( keys(%FixValueMap )) {
          $Data{$CurrKey} = $FixValueMap{$CurrKey};
      }

      # update existing item...
      if ( $SearchResult{ID} ) {

        $Data{ID} = $SearchResult{ID};
        my $Result = undef;
        if ( $Config{ObjectType} eq 'Contact') {
            $Result = _KIXAPIUpdateContact({
                %Config, Client => $KIXClient, Contact => \%Data
            });
        }
        elsif( $Config{ObjectType} eq 'Organisation') {
            $Result = _KIXAPIUpdateOrg({
                %Config, Client => $KIXClient, Organization => \%Data
            });
        }
        print STDOUT "$LineCount: error while updating!\n" if( !$Result );
      }

      # create new item...
      else {
        my $Result = undef;
        if ( $Config{ObjectType} eq 'Contact') {
            $Result = _KIXAPICreateContact({
                %Config, Client => $KIXClient, Contact => \%Data
            });
        }
        elsif( $Config{ObjectType} eq 'Organisation') {
            $Result = _KIXAPICreateOrg({
                %Config, Client => $KIXClient, Organization => \%Data
            });
        }
        print STDOUT "$LineCount: error while creating!\n" if( !$Result );
      }
      print STDOUT "$LineCount done.\n" if( $Config{Verbose} > 2);

  }
  print STDOUT "$LineCount items processed.\n" if( $Config{Verbose} > 1);


}


# finish...
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
      .".\n" if( $Config{Verbose} > 2);

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

  my $RequestBody = {
    "Contact" => {
        %{$Params{Contact}}
    }
  };

  $Params{Client}->PATCH( "/api/v1/contacts/".$Params{Contact}->{ID},
      encode("utf-8", to_json( $RequestBody ))
  );

  #  update ok...
  if( $Params{Client}->responseCode() eq "200") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{ContactID};
    print STDOUT "Updated contact $Result\n" if( $Config{Verbose} > 3);
  }
  else {
    print STDERR "Updating contact failed (Response ".$Params{Client}->responseCode().")!\n";

    print STDERR "Header: ".$Params{Client}->responseHeaders()."\n";
    print STDERR "Request Body: ".to_json( $RequestBody )."\n";
  }

  return $Result;

}



sub _KIXAPICreateContact {

  my %Params = %{$_[0]};
  my $Result = 0;

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
    print STDOUT "Created contact $Result\n" if( $Config{Verbose} > 3);
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

    if( $Config{OrgSearch} ) {
      @QueryParams =  ("search=".uri_escape( to_json( $Query)),);

    }
    else {
        @QueryParams =  ("filter=".uri_escape( to_json( $Query)),);
    }

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
    print STDOUT "Updated organisation $Result\n" if( $Config{Verbose} > 3);
  }
  else {
    print STDERR "Updating contact failed (Response ".$Params{Client}->responseCode().")!\n";
  }

  return $Result;

}



sub _KIXAPICreateOrg {

  my %Params = %{$_[0]};
  my $Result = 0;

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
    print STDOUT "Created organisation $Result\n" if( $Config{Verbose} > 3);

  }

  return $Result;

}





sub _DBConnect {
  my (%Params) = @_;

  my $DBH = DBI->connect(
    $Params{DSN},
    $Params{DBUser},
    $Params{DBPassword},
  );
  if( !$DBH ) {
    print STDERR "\nCannot connect to database "
      . "(user: $Params{DBUser}; DSN: $Params{DSN})!\n";
  }
  print STDOUT "\nConnected to database "
      . "(user: $Params{DBUser})." if( $Config{Verbose} );

  return $DBH;
}






1;
