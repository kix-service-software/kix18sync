#!/usr/bin/perl -w
# --
# bin/kix18.ManageRoles.pl - ex-/imports roles and permissions from/to KIX18
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

This script retrieves role and permission infomation from a KIX18 by communicating with its REST-API.

Examples
kix18.ManageRoles.pl --help
kix18.ManageRoles.pl --config ./config/kix18.ManageRoles.cfg --dir export -d /tmp
kix18.ManageRoles.pl --config ./config/kix18.ManageRoles.cfg --dir import --f ./sample/RoleData_Sample.csv --verbose 2


=head1 OPTIONS

=over

=item
--dir: direction (import|export), "export" if not given
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
--d: output directory to which role permissions are written (if direction "export")
=cut

=item
--f: input file (if direction "import")
=cut

=item
--verbose: makes the script verbose (1..4)
=cut

=item
--help show help message
=cut

=back


=head1 REQUIREMENTS

The script has been developed using CentOS8 or Ubuntu as target plattform. Following packages must be installed

=head2 CentOS8

=over

=item
shell> sudo yum install perl-Config-Simple perl-REST-Client perl-JSO perl-LWP-Protocol-https perl-DBI perl-URI perl-Pod-Usage perl-Getopt-Long  libtext-csv-perl
=cut

=back

=cut

=head2 Ubuntu

=over

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
  "config=s"  => \$Config{ConfigFilePath},
  "url=s"     => \$Config{KIXURL},
  "u=s"       => \$Config{KIXUserName},
  "p=s"       => \$Config{KIXPassword},
  "dir=s"     => \$Config{Direction},
  "d=s"       => \$Config{CSVOutputDir},
  "f=s"       => \$Config{CSVFile},
  "verbose=i" => \$Config{Verbose},
  "help"      => \$Help,
);

if( $Help ) {
  pod2usage( -verbose => 3);
  exit(-1)
}


if( $Config{CSVFile} ) {
  my $basename = basename( $Config{CSVFile} );
  my $dirname  = dirname( $Config{CSVFile} );
  $Config{CSVInputDir} = $dirname;
  $Config{CSVFile} = $basename;
}


# read config file...
my %FileConfig = ();
if( $Config{ConfigFilePath} ) {
    print STDOUT "\nReading config file $Config{ConfigFilePath} ..." if( $Config{Verbose});
    Config::Simple->import_from( $Config{ConfigFilePath}, \%FileConfig);

    for my $CurrKey ( keys( %FileConfig )) {
      my $LocalKey = $CurrKey;
      $LocalKey =~ s/(CSV\.|KIXAPI.)//g;
      $Config{$LocalKey} = $FileConfig{$CurrKey} if(!$Config{$LocalKey});
    }

}

# set default direction...
$Config{Direction} = $Config{Direction} || 'export';

# check requried params...
for my $CurrKey (qw{KIXURL KIXUserName KIXPassword Direction}) {
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

my $Result = 0;

# lookup existing roles types...
my %RoleList = _KIXAPIRoleNameList(
  { %Config, Client => $KIXClient}
);


# lookup permission types...
my %PermTypeList = _KIXAPIPermissionTypeList(
  { %Config, Client => $KIXClient}
);
my %RevPermTypeList = reverse(%PermTypeList);

# lookup validities...
my %ValidList = _KIXAPIValidList(
  { %Config, Client => $KIXClient}
);
my %RevValidList = reverse(%ValidList);


# lookup teams...
my %TeamList = _KIXAPITeamList(
  { %Config, Client => $KIXClient}
);
my %RevTeamList = reverse(%TeamList);


# import CSV-data...
my $ResultData = ();


if ( $Config{Direction} eq 'import') {

  # read source file...
  my $RoleData = _ReadFile( { %Config} );
  exit(-1) if !$RoleData;

  # throw away first line (header)..
  shift( @{$RoleData} );

  # sort by role name, target, type
  my @SortedRoles = sort {
    $a->[0] cmp $b->[0] ||
    $a->[5] cmp $b->[5] ||
    $a->[4] cmp $b->[4]
  } @{$RoleData};

  # for each role...
  my $LineCount = 0;
  my %PrevRole = ();
  $PrevRole{Name} = "";

  LINE:
  for my $CurrRolePerm ( @SortedRoles ) {
      $LineCount++;
      my %CurrRP = qw();
      print STDOUT "\nline $LineCount: <".join( ";", @{$CurrRolePerm}).">..." if( $Config{Verbose} > 1);

      $CurrRP{'Name'}     = $CurrRolePerm->[0];
      $CurrRP{'UsageContext'} = $CurrRolePerm->[1];
      $CurrRP{'RoleComment'}  = $CurrRolePerm->[2];
      $CurrRP{'Valid'}        = $CurrRolePerm->[3];
      $CurrRP{'PermType'}     = $CurrRolePerm->[4];
      $CurrRP{'Target'}       = $CurrRolePerm->[5];
      $CurrRP{'PermComment'}  = $CurrRolePerm->[6];
      $CurrRP{'CREATE'}       = $CurrRolePerm->[7];
      $CurrRP{'READ'}         = $CurrRolePerm->[8];
      $CurrRP{'UPDATE'}       = $CurrRolePerm->[9];
      $CurrRP{'DELETE'}       = $CurrRolePerm->[10];
      $CurrRP{'DENY'}         = $CurrRolePerm->[11];

      # get UsageContextID
      # Agent    == 1
      # Customer == 2
      if( $CurrRP{'UsageContext'} eq 'Agent') {
          $CurrRP{'UsageContextID'} = 1;
      }
      elsif( $CurrRP{'UsageContext'} eq 'Customer' ) {
          $CurrRP{'UsageContextID'} = 2;
      }
      else {
        $CurrRP{'UsageContextID'} = 0;
      }

      # set valid ID
      $CurrRP{'ValidID'} = $ValidList{ $CurrRP{'Valid'} } || $ValidList{'invalid'};

      # calculate value (permission bit mask)...
      $CurrRP{'Value'} = 0;
      if( length($CurrRP{'CREATE'}) && $CurrRP{'CREATE'} ne '-') {
          $CurrRP{'Value'} = ( int($CurrRP{'Value'}) | 1);
      }
      if( length($CurrRP{'READ'}) && $CurrRP{'READ'} ne '-') {
          $CurrRP{'Value'} = ( int($CurrRP{'Value'}) | 2);
      }
      if( length($CurrRP{'UPDATE'}) && $CurrRP{'UPDATE'} ne '-') {
          $CurrRP{'Value'} = ( int($CurrRP{'Value'}) | 4);
      }
      if( length($CurrRP{'DELETE'}) && $CurrRP{'DELETE'} ne '-') {
          $CurrRP{'Value'} = ( int($CurrRP{'Value'}) | 8);
      }
      if( length($CurrRP{'DENY'}) && $CurrRP{'DENY'} ne '-') {
          $CurrRP{'Value'} = ( int($CurrRP{'Value'}) | 61440);
      }

      # lookup permission type id...
      $CurrRP{'TypeID'} = $PermTypeList{ $CurrRP{'PermType'} } || '';
      if(!$CurrRP{'TypeID'} ) {

      }

      # if another role than before...
      if( $PrevRole{Name} ne $CurrRP{'Name'} ) {

          # check if role does exist yet...
          if( $RoleList{$CurrRP{'Name'}}
            && $RoleList{$CurrRP{'Name'}}->{ID})
          {
            $CurrRP{'ID'} = $RoleList{$CurrRP{'Name'}}->{ID};
          }
          # totally new role => create role...
          if( !$CurrRP{'ID'} ) {
            $CurrRP{'ID'} = _KIXAPICreateRole(  { %Config,
              Client => $KIXClient,
              Role   => {
                Name         => $CurrRP{'Name'},
                UsageContext => $CurrRP{'UsageContextID'},
                Comment      => $CurrRP{'RoleComment'},
                ValidID      => $CurrRP{'ValidID'},
              }
            }) || '' ;

            next LINE if(!$CurrRP{'ID'});
            print STDOUT "\nCreated new role <"
              .$CurrRP{'Name'}."/"
              .$CurrRP{'ID'}.">..."
              if( $Config{Verbose} > 2);
          }
          # not so new role => update role props...
          else {
            my $UpdateOK = _KIXAPIUpdateRole(  { %Config,
              Client => $KIXClient,
              Role   => {
                ID           => $CurrRP{'ID'},
                Name         => $CurrRP{'Name'},
                UsageContext => $CurrRP{'UsageContextID'},
                Comment      => $CurrRP{'RoleComment'},
                ValidID      => $CurrRP{'ValidID'},
              }
            });
            next LINE if(!$UpdateOK);

            print STDOUT "\n\tUpdated existing role <"
              .$CurrRP{'Name'}."/"
              .$CurrRP{'ID'}.">..."
              if( $Config{Verbose} > 2);
          }

          # drop all existing permissions...
          for my $CurrExistPerm ( @{$RoleList{$CurrRP{'Name'}}->{Permissions}} ) {

              if( $CurrExistPerm->{ID} && $CurrRP{'ID'} ) {
                  my $RemoveOK = _KIXAPIRoleDeletePermission(  { %Config,
                    Client => $KIXClient,
                    RoleID => $CurrRP{'ID'},
                    PermID => $CurrExistPerm->{ID},
                  });

                  next LINE if(!$RemoveOK);

              }
          }
          print STDOUT "\n\tRemoved all existing permissions for role <"
            .$CurrRP{'Name'}."/"
            .$CurrRP{'ID'}.">..."
            if( $Config{Verbose} > 2);

      }
      # compare role properties with previous line...
      else {
          $CurrRP{'ID'} = $PrevRole{'ID'};

          # to update or not to update, that is here the question...
          if( $CurrRP{'Name'} ne $PrevRole{'Name'}
              || $CurrRP{'UsageContext'} ne $PrevRole{'UsageContext'}
              || $CurrRP{'RoleComment'} ne $PrevRole{'RoleComment'}
              || $CurrRP{'Valid'} ne $PrevRole{'Valid'}
          )
          {
            print STDOUT "\nSkipped different role properties in repeated role <"
              .$CurrRP{'Name'}."/"
              .$CurrRP{'ID'}.">..."
              if( $Config{Verbose} );
          }
      }

      # check target for name lookup
      while( $CurrRP{'Target'} =~ /.+(<TeamName2ID\:)(.+)>.+/) {
        my $TeamName = $2;
        my $Pattern = $1.$TeamName.'>';
        my $TeamID = $TeamList{$TeamName} || '';

        if( !$TeamID ) {
          print STDERR "\nNo TeamID fround for <$TeamName> (line )!\n";
          $TeamID =  "UnknownTeam_$TeamName";
        }
        $CurrRP{'Target'} =~ s/$Pattern/$TeamID/eg;
      }

      # store current permission...
      my $Result = _KIXAPIRolePermissionCreate(  { %Config,
        Client => $KIXClient,
        RoleID  => $CurrRP{'ID'},
        Permission => {
          Target  => $CurrRP{'Target'},
          TypeID  => $CurrRP{'TypeID'},
          Value   => $CurrRP{'Value'},
          Comment => $CurrRP{'PermComment'},
        }
      });
      if( !$Result ) {
        next LINE;
      }
      elsif( $Config{Verbose} > 3) {
        print STDOUT "\n\tStored permission <".$CurrRP{Value}
          ."> on <".$CurrRP{Target}
          ."> for role <".$CurrRP{'Name'}."/"
          .$CurrRP{'ID'}.">...";
      }


      # remember current role...
      %PrevRole = %CurrRP;
    }

}
else {

  my @Roles = qw{};
  my @HeadRow = qw{};

  push( @HeadRow, 'Role Name' );
  push( @HeadRow, 'Usage Context' );
  push( @HeadRow, 'Role Comment' );
  push( @HeadRow, 'Valid' );
  push( @HeadRow, 'Permission Type' );
  push( @HeadRow, 'Target' );
  push( @HeadRow, 'Permission Comment' );
  push( @HeadRow, 'CREATE' );
  push( @HeadRow, 'READ' );
  push( @HeadRow, 'UPDATE' );
  push( @HeadRow, 'DELETE' );
  push( @HeadRow, 'DENY' );
  push( @Roles, \@HeadRow);

  for my $CurrKey( sort( keys(%RoleList)) ) {

    my $CurrRoleData = $RoleList{$CurrKey};

    my $RoleName     = $CurrRoleData->{Name} || '';
    my $UsageContext = $CurrRoleData->{UsageContext} || '';
    my $RoleComment  = $CurrRoleData->{Comment} || '';
    my $ValidStr     = $RevValidList{$CurrRoleData->{ValidID}} || '';

    for my $CurrPerm ( @{$CurrRoleData->{Permissions}} ) {
      my @CurrRP = qw{};

      my $PermTypeStr  = $RevPermTypeList{$CurrPerm->{TypeID}}  || '';
      my $TargetStr    = $CurrPerm->{Target} || '';
      my $CommentStr   = $CurrPerm->{Comment} || '';
      my $PermValue    = int( $CurrPerm->{Value} || 0);

      my $CREATE = $PermValue &  1 ? 'C' : '-';
      my $READ   = $PermValue &  2 ? 'R' : '-';
      my $UPDATE = $PermValue &  4 ? 'U' : '-';
      my $DELETE = $PermValue &  8 ? 'D' : '-';
      my $DENY   = $PermValue & 61440 ? 'N' : '-';

      push( @CurrRP, $RoleName );
      push( @CurrRP, $UsageContext );
      push( @CurrRP, $RoleComment );
      push( @CurrRP, $ValidStr );
      push( @CurrRP, $PermTypeStr );
      push( @CurrRP, $TargetStr );
      push( @CurrRP, $CommentStr );
      push( @CurrRP, $CREATE );
      push( @CurrRP, $READ );
      push( @CurrRP, $UPDATE );
      push( @CurrRP, $DELETE );
      push( @CurrRP, $DENY );

      push( @Roles, \@CurrRP);

    }

  }

  my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime( time );
  my $Timestamp = sprintf (
    "%04d%02d%02d-%02d%02d%02d",
    $year+1900, $mon+1, $mday, $hour, $min, $sec
  );
  $ResultData->{'RolesExport_'.$Timestamp.'.csv'} = \@Roles;

  _WriteExport( { %Config, Data => $ResultData} );


}


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
# ROLE HANDLING FUNCTIONS KIX-API
sub _KIXAPIRoleNameList {

  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};


  my @QueryParams = (
    "include=Permissions",
  );
  my $QueryParamStr = join( ";", @QueryParams);
  $Params{Client}->GET( "/api/v1/system/roles?$QueryParamStr");

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
      $RoleData{ID}           = $CurrItem->{ID};
      $RoleData{Name}         = $CurrItem->{Name};
      $RoleData{ValidID}      = $CurrItem->{ValidID};
      $RoleData{Permissions}  = $CurrItem->{Permissions};
      $RoleData{UsageContext} = join( ",", @{$CurrItem->{UsageContextList}});

      $Result{ $CurrItem->{Name} } = \%RoleData;
    }

  }

  return %Result;
}


sub _KIXAPIRolePermissionCreate {

  my %Params = %{$_[0]};
  my $Result = 0;

  return $Result if ( !$Params{RoleID} );
  return $Result if ( !$Params{Permission}->{'Target'} );
  return $Result if ( !$Params{Permission}->{'TypeID'} );

  my $RequestBody = {
    "Permission" => {
      %{$Params{Permission}}
    }
  };

  $Params{Client}->POST(
      "/api/v1/system/roles/".$Params{RoleID}."/permissions",
      encode("utf-8",to_json( $RequestBody ))
  );

  #  create ok...
  if( $Params{Client}->responseCode() eq "201") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{PermissionID};
  }
  elsif( $Params{Client}->responseCode() eq "409" ) {
    print STDERR "Creating role permission failed - ambigous role permission to same target and type!\n";
  }
  else {
    print STDERR "Creating role permission failed (Response ".$Params{Client}->responseCode().")!\n";
  }

  return $Result;

}


sub _KIXAPIRoleDeletePermission {

  my %Params = %{$_[0]};
  my $Result = 0;
  my $Client = $Params{Client};

  $Params{Client}->DELETE( "/api/v1/system/roles/".$Params{RoleID}."/permissions/".$Params{PermID});

  if( $Client->responseCode() ne "204") {
    print STDERR "\nDeleting role permission failed (Response ".$Client->responseCode().")!\n";
    return 0;
  }
  else {
    $Result = 1;
  }

  return $Result;
}


sub _KIXAPIPermissionTypeList {

  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};

  $Params{Client}->GET( "/api/v1/system/roles/permissiontypes");

  if( $Client->responseCode() ne "200") {
    print STDERR "\nSearch for role permission types failed (Response "
      . $Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    for my $CurrItem ( @{$Response->{PermissionType}}) {
      $Result{ $CurrItem->{Name} } = $CurrItem->{ID};
    }

  }

  return %Result;
}


sub _KIXAPICreateRole {

  my %Params = %{$_[0]};
  my $Result = 0;

  my $RequestBody = {
    "Role" => {
        %{$Params{Role}}
    }
  };

  $Params{Client}->POST(
      "/api/v1/system/roles",
      encode("utf-8",to_json( $RequestBody ))
  );

  #  create ok...
  if( $Params{Client}->responseCode() eq "201") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{RoleID};
  }
  else {
    print STDERR "Creating role failed (Response ".$Params{Client}->responseCode().")!\n";
    print STDERR "Role Data:".Dumper($Params{Role})."\n";
  }

  return $Result;

}


sub _KIXAPIUpdateRole {

  my %Params = %{$_[0]};
  my $Result = 0;

  my $RequestBody = {
    "Role" => {
        %{$Params{Role}}
    }
  };

  $Params{Client}->PATCH(
      "/api/v1/system/roles/".$Params{Role}->{ID},
      encode("utf-8",to_json( $RequestBody ))
  );

  #  update ok...
  if( $Params{Client}->responseCode() eq "200") {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{RoleID};
  }
  else {
    print STDERR "Updating role failed (Response ".$Params{Client}->responseCode().")!\n";
  }

  return $Result;

}


sub _KIXAPITeamList{

  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};

  $Params{Client}->GET( "/api/v1/system/ticket/queues");

  if( $Client->responseCode() ne "200") {
    print STDERR "\nSearch for teams failed (Response ".$Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    for my $CurrItem ( @{$Response->{Queue}}) {
      $Result{ $CurrItem->{'Fullname'} } = $CurrItem->{QueueID};
    }
  }

  return %Result;
}

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


#-------------------------------------------------------------------------------
# FILE HANDLING FUNCTIONS

sub _ReadFile {
  my %Params = %{$_[0]};
  my @Result = ();


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
      #auto_diag => 1,
      sep_char   => $Params{CSVSeparator},
      quote_char => $Params{CSVQuote},
      #eol => "\r\n",
    }
  );

  open my $FH, "<:encoding(".$Params{CSVEncoding}.")", $Config{CSVInputDir}."/".$Params{CSVFile}
    or die "Could not read $Config{CSVInputDir}/$Params{CSVFile}: $!";

  my $Result = $InCSV->getline_all ($FH);
  print STDOUT "Reading import file $Params{CSVFile}".".\n" if( $Config{Verbose} > 2);
  print STDOUT "Got".Dumper($Result).".\n" if( $Config{Verbose} > 3);

  close $FH;

  return $Result;
}


sub _WriteExport {
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
      #eol => "\r\n",
    }
  );

  for my $CurrFile ( keys( %{$Params{Data}}) ) {

    my $ResultFileName = $CurrFile;
    $Params{CSVOutputDir} = $Params{CSVOutputDir} || '.';
    my $OutputFileName = $Params{CSVOutputDir}."/".$ResultFileName;

    open ( my $FH, ">:encoding(".$Params{CSVEncoding}.")",
      $OutputFileName) or die "Could not write $OutputFileName: $!";

    for my $CurrLine ( @{$Params{Data}->{$CurrFile}} ) {
      $OutCSV->print ($FH, $CurrLine );
    }

    print STDOUT "\nWriting export to <$OutputFileName>.";
    close $FH or die "Error while writing $Params{CSVOutput}: $!";

  }

}


1;
