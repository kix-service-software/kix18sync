#!/usr/bin/perl
package KIX18API;

use utf8;
use Encode qw/encode decode/;
use Data::Dumper;
use REST::Client;
use JSON;
use URI::Escape;

# ------------------------------------------------------------------------------
# KIX API Helper FUNCTIONS
sub Connect {
  my (%Params) = @_;
  my $Result = 0;

  # connect to webservice
  my $AccessToken = "";
  my $Headers = {Accept => 'application/json', };
  my $RequestBody = {
  	"UserLogin" => $Params{KIXUserName},
  	"Password" =>  $Params{KIXPassword},
  	"UserType" => "Agent"
  };

  my $Client = REST::Client->new(
    host    => $Params{KIXURL},
    timeout => $Params{APITimeOut} || 15,
  );
  $Client->getUseragent()->proxy(['http','https'], $Params{Proxy});

  if( $Params{NoSSLVerify} ) {
    $Client->getUseragent()->ssl_opts(verify_hostname => 0);
    $Client->getUseragent()->ssl_opts(SSL_verify_mode => 0);
  }

  $Client->POST(
      "/api/v1/auth",
      to_json( $RequestBody ),
      $Headers
  );

  if( $Client->responseCode() ne "201") {
    print STDERR "\nCannot login to $Params{KIXURL}/api/v1/auth (user: "
      .$Params{KIXUserName}.". Response ".$Client->responseCode().")!\n";
    exit(-1);
  }
  else {
    my $Response = from_json( $Client->responseContent() );
    $AccessToken = $Response->{Token};
    print STDOUT "Connected to $Params{KIXURL}/api/v1/ (user: "
      ."$Params{KIXUserName}).\n" if( $Params{Verbose} > 1);

  }

  $Client->addHeader('Accept', 'application/json');
  $Client->addHeader('Content-Type', 'application/json');
  $Client->addHeader('Authorization', "Token ".$AccessToken);

  return $Client;
}




#-------------------------------------------------------------------------------
# SLA HANDLING FUNCTIONS KIX-API
sub SLAValueLookup {
  my %Params = %{$_[0]};
  my $Result = "";
  my $Client = $Params{Client};

  my %SLAList = ListSLA(
    { %Config, Client => $Client }
  );

  if( $Params{Name} && $SLAList{ $Params{Name} } ) {
    $Result = $SLAList{ $Params{Name}}->{ID};
  }

  return $Result;
}

sub ListSLA {
  my %Params = %{$_[0]};
  my %Result = ();
  my $Client = $Params{Client};

  $Client->GET( "/api/v1/system/slas");

  if( $Client->responseCode() ne "200") {
    print STDERR "\nSearch for SLAs failed (Response ".$Client->responseCode().")!\n";
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



sub UpdateSLA {

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



sub CreateSLA {

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
sub SearchContact {

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
      .".\n" if( $Params{Verbose} > 3);

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



sub UpdateContact {

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



sub CreateContact {

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
sub SearchOrg {

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
      .".\n" if( $Params{Verbose} > 2);

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



sub UpdateOrg {

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



sub CreateOrg {

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
sub RoleList {

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



sub SearchUser {

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
      .".\n" if( $Params{Verbose} > 3);

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



sub UpdateUser {

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



sub CreateUser {

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

sub GetAssetClass {

    my %Params = %{$_[0]};
    my %Result = (
       ID => 0,
       Msg => ''
    );
    my $Client = $Params{Client};

    my @ResultItemData = qw{};
    my @Conditions = qw{};

    print STDOUT "Get asset class info <$Params{AssetClass}/$Params{AssetClassID}>"
      .".\n" if( $Params{Verbose} > 3);

    my $Query = {};
    my @QueryParams = (
      "include=definitions"
    );
    my $QueryParamStr = join( ";", @QueryParams);

    $Params{Client}->GET( "/api/v1/system/cmdb/classes/".$Params{AssetClassID}."?$QueryParamStr");

    if( $Client->responseCode() ne "200") {
      $Result{Msg} = "Lookup for asset class failed (Response ".$Client->responseCode().")!";
    }
    else {

      my $Response = from_json( $Client->responseContent() );
      if( !$Response->{ConfigItemClass}  ) {
        $Result{Msg} = "Not found.";
      }
      else {
        $Result{Data} = $Response->{ConfigItemClass};
      }
    }

   return %Result;
}



sub SearchAsset {

    my %Params = %{$_[0]};
    my %Result = (
       ID => 0,
       Msg => ''
    );
    my $Client = $Params{Client};

    my @ResultItemData = qw{};
    my @Conditions = qw{};

    my $IdentAttr  = $Params{Identifier} || "Number";
    my $IdentStrg  = $Params{SearchValue} || "";

    print STDOUT "Search asset by "
      ." <$IdentAttr> EQ '$IdentStrg'"
      .".\n" if( $Params{Verbose} > 3);
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



sub UpdateAsset {

  my %Params = %{$_[0]};
  my $Result = 0;

  my $RequestBody = {
    "ConfigItemVersion" => $Params{'Asset'}->{'Version'},
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



sub CreateAsset {

  my %Params = %{$_[0]};
  my $Result = 0;

  delete($Params{'Asset'}->{'Number'});
  my $RequestBody = {
    'ConfigItem' => $Params{'Asset'},
  };

#print STDERR "\n SubmitBody".Dumper($RequestBody)."...";

  $Params{Client}->POST(
      "/api/v1/cmdb/configitems",
      encode("utf-8", to_json( $RequestBody ))
  );

  if( $Params{Client}->responseCode() ne "201") {
    print STDERR "\nCreating asset failed (Response ".$Params{Client}->responseCode().")!\n";
    my $Response = from_json( $Params{Client}->responseContent() );
    print STDERR "\t".( $Response->{'Message'} )."\n";
    $Result = 0;
  }
  else {
    my $Response = from_json( $Params{Client}->responseContent() );
    $Result = $Response->{ConfigItemID};
  }

  return $Result;

}



sub GeneralCatalogValueLookup {

  my %Params = %{$_[0]};
  my $Result = "";
  my $Client = $Params{Client};
  my $Class  = $Params{Class} || "-";
  my $Value  = $Params{Value} || "-";
  my $Valid  = $Params{Valid} || "valid";

  my %ValueList = GeneralCatalogList(
    { %Config, Client => $Client, Class => $Class}
  );

  if( %ValueList && $ValueList{$Value} ) {
    $Result = $ValueList{$Value};
  }

  return $Result;
}



sub GeneralCatalogList {

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

  $Client->GET( "/api/v1/system/generalcatalog?$QueryParamStr");

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
sub ValidList {

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



sub CalendarList {

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



sub DynamicFieldList {

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





1;
