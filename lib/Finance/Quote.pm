#!/usr/bin/perl -w
#
#    Copyright (C) 1998, Dj Padzensky <djpadz@padz.net>
#    Copyright (C) 1998, 1999 Linas Vepstas <linas@linas.org>
#    Copyright (C) 2000, Yannick LE NY <y-le-ny@ifrance.com>
#    Copyright (C) 2000, Paul Fenwick <pjf@cpan.org>
#    Copyright (C) 2000, Brent Neal <brentn@users.sourceforge.net>
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
#    02110-1301, USA
#
#
# This code derived from Padzensky's work on package Finance::YahooQuote,
# but extends its capabilites to encompas a greater number of data sources.
#
# This code was developed as part of GnuCash <http://www.gnucash.org/>

package Finance::Quote;
require 5.005;

use strict;
use Exporter ();
use Carp;
use Finance::Quote::UserAgent;
use HTTP::Request::Common;
use Encode;
use JSON qw( decode_json );
use Data::Dumper;

use vars qw/@ISA @EXPORT @EXPORT_OK @EXPORT_TAGS
            $TIMEOUT @MODULES %MODULES %METHODS $AUTOLOAD
            $ALPHAVANTAGE_CURRENCY_URL $USE_EXPERIMENTAL_UA/;

@MODULES = qw/
    AEX
    AIAHK
    ASEGR
    ASX
    AlphaVantage
    BMONesbittBurns
    BSEIndia
    BSERO
    Bloomberg
    Bourso
    CSE
    Cdnfundlibrary
    Citywire
    Cominvest
    Currencies
    DWS
    Deka
    FTPortfolios
    FTfunds
    Fidelity
    FidelityFixed
    Finanzpartner
    Fool
    Fundata
    GoldMoney
    HEX
    HU
    IEXCloud
    IndiaMutual
    LeRevenu
    MStaruk
    ManInvestments
    Morningstar
    MorningstarAU
    MorningstarCH
    MorningstarJP
    NSEIndia
    NZX
    OnVista
    Oslobors
    Platinum
    SEB
    SIXfunds
    SIXshares
    TNetuk
    TSP
    TSX
    Tdefunds
    Tdwaterhouse
    Tiaacref
    Troweprice
    Trustnet
    USFedBonds
    Union
    VWD
    XETRA
    YahooJSON
    YahooYQL
    ZA
    ZA_UnitTrusts
/;

# Call on the Yahoo API:
#  - "f=l1" should return a single value - the "Last Trade (Price Only)"
#  - "s=" the value of s should be "<FROM><TO>=X"
#         where <FROM> and <TO> are currencies
# Excample: http://finance.yahoo.com/d/quotes.csv?f=l1&s=AUDGBP=X
# Documentation can be found here:
#     http://code.google.com/p/yahoo-finance-managed/wiki/csvQuotesDownload
$ALPHAVANTAGE_CURRENCY_URL = "https://www.alphavantage.co/query?function=CURRENCY_EXCHANGE_RATE";

@ISA    = qw/Exporter/;
@EXPORT = ();
@EXPORT_OK = qw/fidelity troweprice asx tiaacref
                currency_lookup/;
@EXPORT_TAGS = ( all => [@EXPORT_OK]);

# VERSION

$USE_EXPERIMENTAL_UA = 0;

################################################################################
#
# Private Class Methods
#
################################################################################

# Autoload method for obsolete methods.  This also allows people to
# call methods that objects export without having to go through fetch.

sub AUTOLOAD {
  my $method = $AUTOLOAD;
  $method =~ s/.*:://;

  # Force the dummy object (and hence default methods) to be loaded.
  _dummy();

  # If the method we want is in %METHODS, then set up an appropriate
  # subroutine for it next time.

  if (exists($METHODS{$method})) {
    eval qq[sub $method {
      my \$this;
      if (ref \$_[0]) {
        \$this = shift;
      }
      \$this ||= _dummy();
      \$this->fetch("$method",\@_);
     }];
    carp $@ if $@;
    no strict 'refs'; # So we can use &$method
    return &$method(@_);
  }

  carp "$AUTOLOAD does not refer to a known method.";
}

# Dummy destroy function to avoid AUTOLOAD catching it.
sub DESTROY { return; }

# _convert (private object method)
#
# This function converts between one currency and another.  It expects
# to receive a hashref to the information, a reference to a list
# of the stocks to be converted, and a reference to a  list of fields
# that conversion should apply to.

{
  my %conversion;   # Conversion lookup table.

  sub _convert {
    my $this = shift;
    my $info = shift;
    my $stocks = shift;
    my $convert_fields = shift;
    my $new_currency = $this->{"currency"};

    # Skip all this unless they actually want conversion.
    return unless $new_currency;

    foreach my $stock (@$stocks) {
      my $currency;

      # Skip stocks that don't have a currency.
      next unless ($currency = $info->{$stock,"currency"});

      # Skip if it's already in the same currency.
      next if ($currency eq $new_currency);

      # Lookup the currency conversion if we haven't
      # already.
      unless (exists $conversion{$currency,$new_currency}) {
        $conversion{$currency,$new_currency} =
          $this->currency($currency,$new_currency);
      }

      # Make sure we have a reasonable currency conversion.
      # If we don't, mark the stock as bad.
      unless ($conversion{$currency,$new_currency}) {
        $info->{$stock,"success"} = 0;
        $info->{$stock,"errormsg"} =
          "Currency conversion failed.";
        next;
      }

      # Okay, we have clean data.  Convert it.  Ideally
      # we'd like to just *= entire fields, but
      # unfortunately some things (like ranges,
      # capitalisation, etc) don't take well to that.
      # Hence we pull out any numbers we see, convert
      # them, and stick them back in.  That's pretty
      # yucky, but it works.

      foreach my $field (@$convert_fields) {
        next unless (defined $info->{$stock,$field});

        $info->{$stock,$field} = $this->scale_field($info->{$stock,$field},$conversion{$currency,$new_currency});
      }

      # Set the new currency.
      $info->{$stock,"currency"} = $new_currency;
    }
  }
}

# =======================================================================
# _dummy (private function)
#
# _dummy returns a Finance::Quote object.  I'd really rather not have
# this, but to maintain backwards compatibility we hold on to it.
{
  my $dummy_obj;
  sub _dummy {
    return $dummy_obj ||= Finance::Quote->new;
  }
}

# _load_module (private class method)
# _load_module loads a module(s) and registers its various methods for
# use.

sub _load_modules {
  my $class = shift;
  my $baseclass = ref $class || $class;

  my @modules = @_;

  # Go to each module and use them.  Also record what methods
  # they support and enter them into the %METHODS hash.

  foreach my $module (@modules) {
    my $modpath = "${baseclass}::${module}";
    unless (defined($MODULES{$modpath})) {

      # Have to use an eval here because perl doesn't
      # like to use strings.
      eval "use $modpath;";
      carp $@ if $@;
      $MODULES{$modpath} = 1;

      # Methodhash will continue method-name, function ref
      # pairs.
      my %methodhash = $modpath->methods;
      my %labelhash = $modpath->labels;

      # Find the labels that we can do currency conversion
      # on.

      my $curr_fields_func = $modpath->can("currency_fields")
            || \&default_currency_fields;

      my @currency_fields = &$curr_fields_func;

      # @currency_fields may contain duplicates.
      # This following chunk of code removes them.

      my %seen;
      @currency_fields=grep {!$seen{$_}++} @currency_fields;

      foreach my $method (keys %methodhash) {
        push (@{$METHODS{$method}},
          { function => $methodhash{$method},
            labels   => $labelhash{$method},
            currency_fields => \@currency_fields});
      }
    }
  }
}

# _smart_compare (private method function)
#
# This function compares values where the method depends on the
# type of the parameters.
#  val1, val2
#  scalar,scaler - test for substring match
#  scalar,regex  - test val1 against val2 regex
#  array,scalar  - return true if any element of array substring matches scalar
#  array,regex   - return true if any element of array matches regex
sub _smart_compare {
  my ($val1, $val2) = @_;
 
  if ( ref $val1 eq 'ARRAY' ) {
    if ( ref $val2 eq 'Regexp' ) {
      my @r = grep {$_ =~ $val2} @$val1;
      return @r > 0;
    }
    else {
      my @r = grep {$_ =~ /$val2/} @$val1;
      return @r > 0;
    }
  }
  else {
    if ( ref $val2 eq 'Regexp' ) {
      return $val1 =~ $val2;
    }
    else {
      return index($val1, $val2) > -1
    }
  }
}

# This is a list of fields that will be automatically converted during
# currency conversion.  If a module provides a currency_fields()
# function then that list will be used instead.

sub get_default_currency_fields {
  return qw/last high low net bid ask close open day_range year_range
            eps div cap nav price/;
}

sub get_default_timeout {
  return $TIMEOUT;
}

# get_methods returns a list of sources which can be passed to fetch to
# obtain information.

sub get_methods {
  # Create a dummy object to ensure METHODS is populated
  my $t = Finance::Quote->new();
  return(wantarray ? keys %METHODS : [keys %METHODS]);
}

# =======================================================================
# new (public class method)
#
# Returns a new Finance::Quote object.
#
# Arguments ::
#    - zero or more module names from the Finance::Quote::get_sources list
#    - zero or more named parameters, passes as name => value
#
# Named Parameters ::
#    - timeout           # timeout in seconds for web requests
#    - failover          # boolean value indicating if failover is acceptable
#    - fetch_currency    # currency code for fetch results
#    - required_labels   # array of required labels in fetch results
#    - <module-name>     # hash specific to various Finance::Quote modules
#
# new()                               # default constructor
# new('a', 'b')                       # load only modules a and b
# new(timeout => 30)                  # load all default modules, set timeout
# new('a', fetch_currency => 'X')     # load only module a, use currency X for results
# new('z' => {API_KEY => 'K'})        # load all modules, pass hash to module z constructor
# new('z', 'z' => {API_KEY => 'K'})   # load only module z and pass hash to its constructor
#
# Enivornment Variables ::
#    - FQ_LOAD_QUOTELET  # if no modules named in argument list, use ones in this variable
#
# Return Value ::
#    - Finanace::Quote object

sub new {
  # Create and bless object
  my $self = shift;
  my $class = ref($self) || $self;

  my $this = {};
  bless $this, $class;

  # Default values
  $this->{FAILOVER} = 1;
  $this->{REQUIRED} = [];
  $this->{TIMEOUT} = $TIMEOUT if defined($TIMEOUT);

  # Sort out arguments
  my %named_parameter = (timeout         => ['', 'TIMEOUT'],
                         failover        => ['', 'FAILOVER'],
                         fetch_currency  => ['', 'currency'],
                         required_labels => ['ARRAY', 'REQUIRED']);

  $this->{module_specific_data} = {};
  my @load_modules = ();

  for (my $i = 0; $i < @_; $i++) {
    if (exists $named_parameter{$_[$i]}) {
      die "missing value for named parameter $_[$i]" if $i + 1 == @_;
      die "unexpect type for value of named parameter $_[$i]" if ref $_[$i+1] ne $named_parameter{$_[$i]}[0];

      $this->{$named_parameter{$_[$i]}[1]} = $_[$i+1];
      $i += 1;
    }
    elsif ($i + 1 < @_ and ref $_[$i+1] eq 'HASH') {
      $this->{module_specific_data}->{$_[$i]} = $_[$i+1];
      $i += 1;
    }
    elsif ($_[$i] eq '-defaults') {
      push (@load_modules, @MODULES);
    }
    else {
      push (@load_modules, $_[$i]);
    }
  }

  # Honor FQ_LOAD_QUOTELET if @load_modules is empty
  if ($ENV{FQ_LOAD_QUOTELET} and !@load_modules) {
    @load_modules = split(' ',$ENV{FQ_LOAD_QUOTELET});
  }
  elsif (@load_modules == 0) {
    push(@load_modules, @MODULES);
  }

  $this->_load_modules(@load_modules);

  return $this;
}

sub set_default_timeout {
  $TIMEOUT  = shift;
}

################################################################################
#
# Private Object Methods
#
################################################################################

# _require_test (private object method)
#
# This function takes an array.  It returns true if all required
# labels appear in the arrayref.  It returns false otherwise.
#
# This function could probably be made more efficient.

sub _require_test {
  my $this = shift;
  my %available;
  @available{@_} = ();  # Ooooh, hash-slice.  :)
  my @required = @{$this->{REQUIRED}};
  return 1 unless @required;
  for (my $i = 0; $i < @required; $i++) {
    return 0 unless exists $available{$required[$i]};
  }
  return 1;
}

################################################################################
#
# Public Object Methods
#
################################################################################

# If $str ends with a B like "20B" or "1.6B" then expand it as billions like
# "20000000000" or "1600000000".
#
# This is done with string manipulations so floating-point rounding doesn't
# produce spurious digits for values like "1.6" which aren't exactly
# representable in binary.
#
# Is "B" for billions the only abbreviation from Yahoo?
# Could extend and rename this if there's also millions or thousands.
#
# For reference, if the value was just for use within perl then simply
# substituting to exponential "1.5e9" might work.  But expanding to full
# digits seems a better idea as the value is likely to be printed directly
# as a string.
sub B_to_billions {
  my ($self,$str) = @_;

  ### B_to_billions(): $str
  if ($str =~ s/B$//i) {
    $str = $self->decimal_shiftup ($str, 9);
  }
  return $str;
}

# $str is a number like "123" or "123.45"
# return it with the decimal point moved $shift places to the right
# must have $shift>=1
# eg. decimal_shiftup("123",3)    -> "123000"
#     decimal_shiftup("123.45",1) -> "1234.5"
#     decimal_shiftup("0.25",1)   -> "2.5"
#
sub decimal_shiftup {
  my ($self, $str, $shift) = @_;

  # delete decimal point and set $after to count of chars after decimal.
  # Leading "0" as in "0.25" is deleted too giving "25" so as not to end up
  # with something that might look like leading 0 for octal.
  my $after = ($str =~ s/(?:^0)?\.(.*)/$1/ ? length($1) : 0);

  $shift -= $after;
  # now $str is an integer and $shift is relative to the end of $str

  if ($shift >= 0) {
    # moving right, eg. "1234" becomes "12334000"
    return $str . ('0' x $shift);  # extra zeros appended
  } else {
    # negative means left, eg. "12345" becomes "12.345"
    # no need to prepend zeros since demanding initial $shift>=1
    substr ($str, $shift,0, '.');  # new '.' at shifted spot from end
    return $str;
  }
}

# =======================================================================
# fetch (public object method)
#
# Fetch is a wonderful generic fetcher.  It takes a method and stuff to
# fetch.  It's a nicer interface for when you have a list of stocks with
# different sources which you wish to deal with.
sub fetch {
  my $this = shift if ref ($_[0]);

  $this ||= _dummy();

  my $method = lc(shift);
  my @stocks = @_;

  unless (exists $METHODS{$method}) {
    carp "Undefined fetch-method $method passed to ".
         "Finance::Quote::fetch";
    return;
  }

  # Failover code.  This steps through all available methods while
  # we still have failed stocks to look-up.  This loop only
  # runs a single time unless FAILOVER is defined.
  my %returnhash = ();

  foreach my $methodinfo (@{$METHODS{$method}}) {
    my $funcref = $methodinfo->{"function"};
    next unless $this->_require_test(@{$methodinfo->{"labels"}});
    my @failed_stocks = ();
    %returnhash = (%returnhash,&$funcref($this,@stocks));

    foreach my $stock (@stocks) {
      push(@failed_stocks,$stock)
        unless ($returnhash{$stock,"success"});
    }

    $this->_convert(\%returnhash,\@stocks,
                    $methodinfo->{"currency_fields"});

    last unless $this->{FAILOVER};
    last unless @failed_stocks;
    @stocks = @failed_stocks;
  }

  return wantarray() ? %returnhash : \%returnhash;
}

sub get_failover {
  my $self = shift;
  return $self->{FAILOVER};
}

sub get_fetch_currency {
  my $self = shift;
  return $self->{currency};
}

sub get_required_labels {
  my $self = shift;
  return $self->{REQUIRED};
}

sub get_timeout {
  my $self = shift;
  return $self->{TIMEOUT};
}

sub get_user_agent {
  my $this = shift;

  return $this->{UserAgent} if $this->{UserAgent};

  my $ua;

  if ($USE_EXPERIMENTAL_UA) {
    $ua = Finance::Quote::UserAgent->new;
  } else {
    $ua = LWP::UserAgent->new;
  }

  $ua->timeout($this->{TIMEOUT}) if defined($this->{TIMEOUT});
  $ua->env_proxy;

  $this->{UserAgent} = $ua;

  return $ua;
}

sub isoTime {
  my ($self,$timeString) = @_ ;
  $timeString =~ tr/ //d ;
  $timeString = uc $timeString ;
  my $retTime = "00:00"; # return zero time if unparsable input
  if ($timeString=~m/^(\d+)[\.:UH](\d+)(AM|PM)?/) {
    my ($hours,$mins)= ($1-0,$2-0) ;
    $hours-=12 if ($hours==12);
    $hours+=12 if ($3 && ($3 eq "PM")) ;
    if ($hours>=0 && $hours<=23 && $mins>=0 && $mins<=59 ) {
      $retTime = sprintf ("%02d:%02d", $hours, $mins) ;
    }
  }
  return $retTime;
}

sub set_failover {
  my $self          = shift;
  $self->{FAILOVER} = shift;
}

sub set_fetch_currency {
  my $self          = shift;
  $self->{currency} = shift;
}

sub set_required_labels {
  my $self          = shift;
  $self->{REQUIRED} = shift;
}

sub set_timeout {
  my $self         = shift;
  $self->{TIMEOUT} = shift;
}

# =======================================================================
# store_date (public object method)
#
# Given the various pieces of a date, this functions figure out how to
# store them in both the pre-existing US date format (mm/dd/yyyy), and
# also in the ISO date format (yyyy-mm-dd).  This function expects to
# be called with the arguments:
#
# (inforef, symbol_name, data_hash)
#
# The components of date hash can be any of:
#
# usdate   - A date in mm/dd/yy or mm/dd/yyyy
# eurodate - A date in dd/mm/yy or dd/mm/yyyy
# isodate  - A date in yy-mm-dd or yyyy-mm-dd
# year   - The year in yyyy
# month  - The month in mm or mmm format (i.e. 07 or Jul)
# day  - The day
# today  - A flag to indicate todays date should be used.
#
# The separator for the *date forms is ignored.  It can be any
# non-alphanumeric character.  Any combination of year, month, and day
# values can be provided.  Missing fields are filled in based upon
# today's date.
#
sub store_date
{
    my $this = shift;
    my $inforef = shift;
    my $symbol = shift;
    my $piecesref = shift;

    my ($year, $month, $day, $this_month, $year_specified);
    my %mnames = (jan => 1, feb => 2, mar => 3, apr => 4, may => 5, jun => 6,
      jul => 7, aug => 8, sep => 9, oct =>10, nov =>11, dec =>12);

#    printf "In store_date\n";
#    print "inforef $inforef\n";
#    print "piecesref $piecesref\n";
#    foreach my $key (keys %$piecesref) {
#      printf ("  %s: %s\n", $key, $piecesref->{$key});
#    }

    # Default to today's date.
    ($month, $day, $year) = (localtime())[4,3,5];
    $month++;
    $year += 1900;
    $this_month = $month;
    $year_specified = 0;

    # Process the inputs
    if ((defined $piecesref->{isodate}) && ($piecesref->{isodate})) {
      ($year, $month, $day) = ($piecesref->{isodate} =~ m/(\d+)\W+(\w+)\W+(\d+)/);
      $year += 2000 if $year < 100;
      $year_specified = 1;
#      printf "ISO Date %s: Year %d, Month %s, Day %d\n", $piecesref->{isodate}, $year, $month, $day;
    }

    if ((defined $piecesref->{usdate}) && ($piecesref->{usdate})) {
      ($month, $day, $year) = ($piecesref->{usdate} =~ /(\w+)\W+(\d+)\W+(\d+)/);
      $year += 2000 if $year < 100;
      $year_specified = 1;
#      printf "US Date %s: Month %s, Day %d, Year %d\n", $piecesref->{usdate}, $month, $day, $year;
    }

    if ((defined $piecesref->{eurodate}) && ($piecesref->{eurodate})) {
        ($day, $month, $year) = ($piecesref->{eurodate} =~ /(\d+)\W+(\w+)\W+(\d+)/);
      $year += 2000 if $year < 100;
      $year_specified = 1;
#      printf "Euro Date %s: Day %d, Month %s, Year %d\n", $piecesref->{eurodate}, $day, $month, $year;
    }

    if (defined ($piecesref->{year})) {
      $year = $piecesref->{year};
      $year += 2000 if $year < 100;
      $year_specified = 1;
    }
    $month = $piecesref->{month} if defined ($piecesref->{month});
    $month = $mnames{lc(substr($month,0,3))} if ($month =~ /\D/);
    $day  = $piecesref->{day} if defined ($piecesref->{day});

    $year-- if (($year_specified == 0) && ($this_month < $month));

    $inforef->{$symbol, "date"} =  sprintf "%02d/%02d/%04d", $month, $day, $year;
    $inforef->{$symbol, "isodate"} = sprintf "%04d-%02d-%02d", $year, $month, $day;
}

################################################################################
#
# Public Class or Object Methods
#
################################################################################

# =======================================================================
# Helper function that can scale a field.  This is useful because it
# handles things like ranges "105.4 - 108.3", and not just straight fields.
#
# The function takes a string or number to scale, and the factor to scale
# it by.  For example, scale_field("1023","0.01") would return "10.23".

sub scale_field {
  shift if ref $_[0]; # Shift off the object, if there is one.

  my ($field, $scale) = @_;
  my @chunks = split(/([^0-9.])/,$field);

  for (my $i=0; $i < @chunks; $i++) {
    next unless $chunks[$i] =~ /\d/;
    $chunks[$i] *= $scale;
  }
  return join("",@chunks);
}

# =======================================================================
# currency (public object method)
#
# currency allows the conversion of one currency to another.
#
# Usage: $quoter->currency("USD","AUD");
#  $quoter->currency("15.95 USD","AUD");
#
# undef is returned upon error.

sub currency {
  my $this = shift if (ref($_[0]));
  $this ||= _dummy();

  my ($from, $to) = @_;
  return undef unless ($from and $to);

  $from =~ s/^\s*(\d*\.?\d*)\s*//;
  my $amount = $1 || 1;

  # Don't know if these have to be in upper case, but it's
  # better to be safe than sorry.
  $to = uc($to);
  $from = uc($from);

  return $amount if ($from eq $to); # Trivial case.

  my $ua = $this->get_user_agent;

  my $ALPHAVANTAGE_API_KEY = $ENV{'ALPHAVANTAGE_API_KEY'};
  return undef unless ( defined $ALPHAVANTAGE_API_KEY );

  my $try_cnt = 0;
  my $json_data;
  do {
    $try_cnt += 1;
    my $reply = $ua->request(GET "${ALPHAVANTAGE_CURRENCY_URL}"
      . "&from_currency=" . ${from}
      . "&to_currency=" . ${to}
      . "&apikey=" . ${ALPHAVANTAGE_API_KEY} );

    my $code = $reply->code;
    my $desc = HTTP::Status::status_message($code);
    return undef unless ($code == 200);

    my $body = $reply->content;

    $json_data = JSON::decode_json $body;
    if ( !$json_data || $json_data->{'Error Message'} ) {
      return undef;
    }
#     print "Failed: " . $json_data->{'Note'} . "\n" if (($try_cnt < 5) && ($json_data->{'Note'}));
    sleep (20) if (($try_cnt < 5) && ($json_data->{'Note'}));
  } while (($try_cnt < 5) && ($json_data->{'Note'}));

  my $exchange_rate = $json_data->{'Realtime Currency Exchange Rate'}->{'5. Exchange Rate'};

  {
    local $^W = 0;  # Avoid undef warnings.

    # We force this to a number to avoid situations where
    # we may have extra cruft, or no amount.
    return undef unless ($exchange_rate+0);
  }

if ( $exchange_rate < 0.001 ) {
    # exchange_rate is too little. we'll get more accuracy by using
    # the inverse rate and inverse it
    my $inverse_rate = $this->currency( $to, $from );
    {
        local $^W = 0;
        return undef unless ( $exchange_rate + 0 );
    }
    if ($inverse_rate != 0.0) {
        $exchange_rate = int( 100000000 / $inverse_rate + .5 ) / 100000000;
    }
}

  return ($exchange_rate * $amount);
}

# =======================================================================
# currency_lookup (public object method)
#
# search for available currency codes
#
# Usage: 
#   $currency = $quoter->currency_lookup();
#   $currency = $quoter->currency_lookup( name => "Dollar");
#   $currency = $quoter->currency_loopup( country => qw/denmark/i );
#   $currency = $q->currency_lookup(country => qr/united states/i, number => 840);
#
# If more than one lookup parameter is given all must match for
# a currency to match.
#
# undef is returned upon error.

sub currency_lookup {
  my $this = shift if (ref $_[0]);
  $this ||= _dummy();

  my %params = @_;
  my $currencies = Finance::Quote::Currencies::known_currencies();

  my %attributes = map {$_ => 1} map {keys %$_} values %$currencies;

  for my $key (keys %params ) {
    if ( ! exists $attributes{$key}) {
      warn "Invalid parameter: $key";
      return undef;
    }
  }
  
  while (my ($tag, $check) = each(%params)) {
    $currencies = {map {$_ => $currencies->{$_}} grep {_smart_compare($currencies->{$_}->{$tag}, $check)} keys %$currencies};
  }
  
  return $currencies;
}

# =======================================================================
# parse_csv (public object method)
#
# Grabbed from the Perl Cookbook. Parsing csv isn't as simple as you thought!
#
sub parse_csv
{
    shift if (ref $_[0]); # Shift off the object if we have one.
    my $text = shift;      # record containing comma-separated values
    my @new  = ();

    push(@new, $+) while $text =~ m{
        # the first part groups the phrase inside the quotes.
        # see explanation of this pattern in MRE
        "([^\"\\]*(?:\\.[^\"\\]*)*)",?
           |  ([^,]+),?
           | ,
       }gx;
       push(@new, undef) if substr($text, -1,1) eq ',';

       return @new;      # list of values that were comma-separated
}

# =======================================================================
# parse_csv_semicolon (public object method)
#
# Grabbed from the Perl Cookbook. Parsing csv isn't as simple as you thought!
#
sub parse_csv_semicolon
{
    shift if (ref $_[0]); # Shift off the object if we have one.
    my $text = shift;      # record containing comma-separated values
    my @new  = ();

    push(@new, $+) while $text =~ m{
        # the first part groups the phrase inside the quotes.
        # see explanation of this pattern in MRE
        "([^\"\\]*(?:\\.[^\"\\]*)*)";?
           |  ([^;]+);?
           | ;
       }gx;
       push(@new, undef) if substr($text, -1,1) eq ';';

       return @new;      # list of values that were comma-separated
}

###############################################################################
#
# Legacy Class Methods
#
###############################################################################

sub sources {
  return get_methods();
}

sub default_currency_fields {
  return get_default_currency_fields();
}

###############################################################################
#
# Legacy Class or Object Methods
#
###############################################################################

# =======================================================================
# set_currency (public object method)
#
# set_currency allows information to be requested in the specified
# currency.  If called with no arguments then information is returned
# in the default currency.
#
# Requesting stocks in a particular currency increases the time taken,
# and the likelyhood of failure, as additional operations are required
# to fetch the currency conversion information.
#
# This method should only be called from the quote object unless you
# know what you are doing.

sub set_currency {
  if (@_ == 1 or !ref($_[0])) {
    # Direct or class call - there is no class default currency
    return undef;
  }

  my $this = shift;
  if (defined($_[0])) {
    $this->set_fetch_currency($_[0]);
  }

  return $this->get_fetch_currency();
}

# =======================================================================
# Timeout code.  If called on a particular object, then it sets
# the timout for that object only.  If called as a class method
# (or as Finance::Quote::timeout) then it sets the default timeout
# for all new objects that will be created.

sub timeout {
  if (@_ == 1 or !ref($_[0])) {
    # Direct or class call
    Finance::Quote::set_default_timeout(shift);
    return Finance::Quote::get_default_timeout();
  }

  # Otherwise we were called through an object.  Yay.
  # Set the timeout in this object only.
  my $this = shift;
  $this->set_timeout(shift);
  return $this->get_timeout();
}

###############################################################################
#
# Legacy Object Methods
#
###############################################################################

# =======================================================================
# failover (public object method)
#
# This sets/gets whether or not it's acceptable to use failover techniques.

sub failover {
  my $this = shift;
  my $value = shift;

  $this->set_failover($value) if defined $value;
  return $this->get_failover();
}

# =======================================================================
# require_labels (public object method)
#
# Require_labels indicates which labels are required for lookups.  Only methods
# that have registered all the labels specified in the list passed to
# require_labels() will be called.
#
# require_labels takes a list of required labels.  When called with no
# arguments, the require list is cleared.
#
# This method always succeeds.

sub require_labels {
  my $this = shift;
  my @labels = @_;
  $this->set_required_labels(\@labels);
  return;
}

# =======================================================================
# user_agent (public object method)
#
# Returns a LWP::UserAgent which conforms to the relevant timeouts,
# proxies, and other settings on the particular Finance::Quote object.
#
# This function is mainly intended to be used by the modules that we load,
# but it can be used by the application to directly play with the
# user-agent settings.

sub user_agent {
  my $this = shift;
  return $this->get_user_agent();
}

1;

__END__

=head1 NAME

Finance::Quote - Get stock and mutual fund quotes from various exchanges

=head1 SYNOPSIS

   use Finance::Quote;
   $q = Finance::Quote->new;

   $q->timeout(60);

   $conversion_rate = $q->currency("AUD", "USD");
   $q->set_currency("EUR");  # Return all info in Euros.

   $q->require_labels(qw/price date high low volume/);

   $q->failover(1); # Set failover support (on by default).

   %quotes  = $q->fetch("nasdaq", @stocks);
   $hashref = $q->fetch("nyse", @stocks);

=head1 DESCRIPTION

This module gets stock quotes from various internet sources all over the world.
Quotes are obtained by constructing a quoter object and using the fetch method
to gather data, which is returned as a two-dimensional hash (or a reference to
such a hash, if called in a scalar context).  For example:

    $q = Finance::Quote->new;
    %info = $q->fetch("australia", "CML");
    print "The price of CML is ".$info{"CML", "price"};

The first part of the hash (eg, "CML") is referred to as the stock.
The second part (in this case, "price") is referred to as the label.

=head2 LABELS

When information about a stock is returned, the following standard labels may
be used.  Some custom-written modules may use labels not mentioned here.  If
you wish to be certain that you obtain a certain set of labels for a given
stock, you can specify that using require_labels().

    name         Company or Mutual Fund Name
    last         Last Price
    high         Highest trade today
    low          Lowest trade today
    date         Last Trade Date  (MM/DD/YY format)
    time         Last Trade Time
    net          Net Change
    p_change     Percent Change from previous day's close
    volume       Volume
    avg_vol      Average Daily Vol
    bid          Bid
    ask          Ask
    close        Previous Close
    open         Today's Open
    day_range    Day's Range
    year_range   52-Week Range
    eps          Earnings per Share
    pe           P/E Ratio
    div_date     Dividend Pay Date
    div          Dividend per Share
    div_yield    Dividend Yield
    cap          Market Capitalization
    ex_div       Ex-Dividend Date.
    nav          Net Asset Value
    yield        Yield (usually 30 day avg)
    exchange     The exchange the information was obtained from.
    success      Did the stock successfully return information? (true/false)
    errormsg     If success is false, this field may contain the reason why.
    method       The module (as could be passed to fetch) which found this
                 information.
    type         The type of equity returned

If all stock lookups fail (possibly because of a failed connection) then the
empty list may be returned, or undef in a scalar context.

=head1 INSTALLATION

Please note that the Github repository is not meant for general users
of Finance::Quote for installation.

If you downloaded the Finance-Quote-N.NN.tar.gz tarball from CPAN
(N.NN is the version number, ex: Finance-Quote-1.50.tar.gz),
run the following commands:

    tar xzf Finance-Quote-1.50.tar.gz
    cd Finance-Quote-1.50.tar.gz
    perl Makefile.PL
    make
    make test
    make install

If you have the CPAN module installed:
Using cpanm (Requires App::cpanminus)

    cpanm Finance::Quote

or
Using CPAN shell

    perl -MCPAN -e shell
    install Finance::Quote

=head1 SUPPORT AND DOCUMENTATION

After installing, you can find documentation for this module with the
perldoc command.

    perldoc Finance::Quote

You can also look for information at:

=over

=item Finance::Quote GitHub project

https://github.com/finance-quote/finance-quote

=item Search CPAN

http://search.cpan.org/dist/Finance-Quote

=item The Finance::Quote home page

http://finance-quote.sourceforge.net/

=item The Finance::YahooQuote home page

http://www.padz.net/~djpadz/YahooQuote/

=item The GnuCash home page

http://www.gnucash.org/

=back

=head1 PUBLIC CLASS METHODS

Finance::Quote has public class methods to construct a quoter object, get or
set default class values, and one helper function.

=head2 NEW

    my $q = Finance::Quote->new()
    my $q = Finance::Quote->new('-defaults')
    my $q = Finance::Quote->new('AEX', 'Fool')
    my $q = Finance::Quote->new(timeout => 30)
    my $q = Finance::Quote->new('YahooJSON', fetch_currency => 'EUR')
    my $q = Finance::Quote->new('alphavantage' => {API_KEY => '...'})
    my $q = Finance::Quote->new('IEXCloud', 'iexcloud' => {API_KEY => '...'});

A Finance::Quote object uses one or more methods to fetch quotes for
securities. C<new> constructs a Finance::Quote object and enables the caller
to load only specific methods, set parameters that control the behavior of the
fetch method, and pass method-specific parameters to the corresponding method.

=over

=item C<timeout => T> sets the web request timeout to C<T> seconds

=item C<failover => B> where C<B> is a boolean value indicating if failover is acceptable

=item C<fetch_currency => C> sets the desired currency code to C<C> for fetch results

=item C<required_labels => A> sets the required labels for fetch results to array C<A>

=item C<<Module-name>> as a string is the name of a specific Finance::Quote::Module to load

=item C<<method-name> => H> passes hash C<H> to the method-name constructor

=back

With no arguments, C<new> creates a Finance::Quote object with the default
methods.  If the environment variable FQ_LOAD_QUOTELET is set, then the
contents of FQ_LOAD_QUOTELET (split on whitespace) will be used as the argument
list.  This allows users to load their own custom modules without having to
change existing code. If any method names are passed to C<new> or the flag
'-defaults' is included in the argument list, then FQ_LOAD_QUOTELET is ignored.

When new() is passed one or more class name arguments, an object is created with
only the specified modules loaded.  If the first argument is '-defaults', then
the default modules will be loaded first, followed by any other specified
modules. Note that the FQ_LOAD_QUOTELET environment variable must begin with
'-defaults' if you wish the default modules to be loaded.

Method names correspond to the Perl module in the Finance::Quote module space.
For example, C<Finance::Quote->new('ASX')> will load the module
Finance::Quote::ASX, which provides the method "asx".

=head2 GET_DEFAULT_CURRENCY_FIELDS

    my @fields = Finance::Quote::get_default_currency_fields();

C<get_default_currency_fields> returns the standard list of fields in a quote
that are automatically converted during currency conversion. Individual modules
may override this list.

=head2 GET_DEFAULT_TIMEOUT
  
    my $value = Finance::Quote::get_default_timeout();

C<get_default_timeout> returns the current Finance::Quote default timeout in
seconds for web requests. Finance::Quote does not specify a default timeout,
deferring to the underlying user agent for web requests. So this function
will return undef unless C<set_default_timeout> was previously called.

=head2 SET_DEFAULT_TIMEOUT

    Finance::Quote::set_default_timeout(45);

C<set_default_timeout> sets the Finance::Quote default timeout to a new value.

=head2 GET_METHODS

    my @methods = Finance::Quote::get_methods();

C<get_methods> returns the list of methods that can be passed to C<new> when
creating a quoter object and as the first argument to C<fetch>.

=head1 PUBLIC OBJECT METHODS

=head2 B_TO_BILLIONS

    my $value = $q->B_to_billions("20B");

C<B_to_billions> is a utility function that expands a numeric string with a "B"
suffix to the corresponding multiple of 1000000000.

=head2 DECIMAL_SHIFTUP

    my $value = $q->decimal_shiftup("123.45", 1);  # returns 1234.5
    my $value = $q->decimal_shiftup("0.25", 1);    # returns 2.5

C<decimal_shiftup> moves a the decimal point in a numeric string the specified
number of places to the right.

=head2 FETCH

    my %stocks  = $q->fetch("alphavantage", "IBM", "MSFT", "LNUX");
    my $hashref = $q->fetch("usa", "IBM", "MSFT", "LNUX");

C<fetch> takes a method as its first argument and the remaining arguments are
treated as securities.  If the quoter C<$q> was constructed with a specific
method or methods, then only those methods are available.

When called in an array context, a hash is returned.  In a scalar context, a
reference to a hash will be returned. 

The keys for the returned hash are C<{SECURITY,LABEL}>.  For the above example
call, C<$stocks{"IBM","high"}> is the high value for IBM as determined by the
AlphaVantage method.

=head2 GET_FAILOVER

    my $failover = $q->get_failover();

Failover is when the C<fetch> method attempts to retrieve quote information for
a security from alternate sources when the requested method fails.
C<get_failover> returns a boolean value indicating if the quoter object will
use failover or not.

=head2 SET_FAILOVER

    $q->set_failover(False);

C<set_failover> sets the failover flag on the quoter object. 

=head2 GET_FETCH_CURRENCY

    my $currency = $q->get_fetch_currency();

C<get_fetch_currency> returns either the desired currency code for the quoter
object or undef if no target currency was set during construction or with the
C<set_fetch_currency> function.

=head2 SET_FETCH_CURRENCY

    $q->set_fetch_currency("FRF");  # Get results in French Francs.

C<set_fetch_currency> method is used to request that all information be
returned in the specified currency.  Note that this increases the chance
stock-lookup failure, as remote requests must be made to fetch both the stock
information and the currency rates.  In order to improve reliability and speed
performance, currency conversion rates are cached and are assumed not to change
for the duration of the Finance::Quote object.

Currency conversions are requested through AlphaVantage, which requires an API
key.  Please see Finance::Quote::AlphaVantage for more information.

=head2 GET_REQUIRED_LABELS

    my @labels = $q->get_required_labels();

C<get_required_labels> returns the list of labels that must be populated for a
security quote to be considered valid and returned by C<fetch>.

=head2 SET_REQUIRED_LABELS

    my $labels = ['close', 'isodate', 'last'];
    $q->set_required_labels($labels);

C<set_required_labels> updates the list of required labels for the quoter object.

=head2 GET_TIMEOUT

    my $timeout = $q->get_timeout();

C<get_timeout> returns the timeout in seconds the quoter object is using for
web requests.

=head2 SET_TIMEOUT

    $q->set_timeout(45);

C<set_timeout> updated teh timeout in seconds for the quoter object.

=head2 GET_USER_AGENT

    my $ua = $q->get_user_agent();

C<get_user_agent> returns the LWP::UserAgent the quoter object is using for web
requests.

=head2 ISOTIME

    $q->isoTime("11:39PM");    # returns "23:39"
    $q->isoTime("9:10 AM");    # returns "09:10"

C<isoTime> returns an ISO formatted time.

=head1 PUBLIC CLASS OR OBJECT METHODS

The following methods are available as class methods, but can also be called
from Finance::Quote objects.

=head2 SCALE_FIELD

    my $value = Finance::Quote->scale_field('1023', '0.01')

C<scale_field> is a utility function that scales the first argument by the
second argument.  In the above example, C<value> is C<'10.23'>.

=head2 CURRENCY

    my $value = Finance::Quote->currency('15.95 USD', 'AUD');

C<currency> converts a value with a currency code suffix to another currency
using the current exchange rate returned by the AlphaVantage method.
AlphaVantage requires an API key. See Finance::Quote::AlphaVantage for more
information.

=head2 CURRENCY_LOOKUP

    my $currency = $quoter->currency_lookup();
    my $currency = $quoter->currency_lookup( name => "Caribbean");
    my $currency = $quoter->currency_loopup( country => qw/denmark/i );
    my $currency = $q->currency_lookup(country => qr/united states/i, number => 840);

C<currency_lookup> takes zero or more constraints and filters the list of
currencies known to Finance::Quote. It returns a hash reference where the keys
are ISO currency codes and the values are hash references containing metadata
about the currency. 

A constraint is a key name and either  a scalar or regular expression.  A
currency satisfies the constraint if its metadata hash contains the constraint
key and the value of that metadata field matches the regular expression or
contains the constraint value as a substring.  If the metadata field is an
array, then it satisfies the constraint if any value in the array satisfies the
constraint.

=head2 PARSE_CSV

    my @list = Finance::Quote::parse_csv($string);

C<parse_csv> is a utility function for spliting a comma seperated value string
into a list of terms, treating double-quoted strings that contain commas as a
single value.

=head2 PARSE_CSV_SEMICOLON

    my @list = Finance::Quote::parse_csv_semicolon($string);

C<parse_csv> is a utility function for spliting a semicolon seperated value string
into a list of terms, treating double-quoted strings that contain semicolons as a
single value.

=head1 ENVIRONMENT

Finance::Quote respects all environment that your installed version of
LWP::UserAgent respects.  Most importantly, it respects the http_proxy
environment variable.

=head1 BUGS

There are no ways for a user to define a failover list.

The two-dimensional hash is a somewhat unwieldly method of passing around
information when compared to references

There is no way to override the default behaviour to cache currency conversion
rates.

=head1 COPYRIGHT & LICENSE

 Copyright 1998, Dj Padzensky
 Copyright 1998, 1999 Linas Vepstas
 Copyright 2000, Yannick LE NY (update for Yahoo Europe and YahooQuote)
 Copyright 2000-2001, Paul Fenwick (updates for ASX, maintenance and release)
 Copyright 2000-2001, Brent Neal (update for TIAA-CREF)
 Copyright 2000 Volker Stuerzl (DWS and VWD support)
 Copyright 2000 Keith Refson (Trustnet support)
 Copyright 2001 Rob Sessink (AEX support)
 Copyright 2001 Leigh Wedding (ASX updates)
 Copyright 2001 Tobias Vancura (Fool support)
 Copyright 2001 James Treacy (TD Waterhouse support)
 Copyright 2008 Erik Colson (isoTime)

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

Currency information fetched through this module is bound by the terms and
conditons of the data source.

Other copyrights and conditions may apply to data fetched through this module.
Please refer to the sub-modules for further information.

=head1 AUTHORS

  Dj Padzensky <djpadz@padz.net>, PadzNet, Inc.
  Linas Vepstas <linas@linas.org>
  Yannick LE NY <y-le-ny@ifrance.com>
  Paul Fenwick <pjf@cpan.org>
  Brent Neal <brentn@users.sourceforge.net>
  Volker Stuerzl <volker.stuerzl@gmx.de>
  Keith Refson <Keith.Refson#earth.ox.ac.uk>
  Rob Sessink <rob_ses@users.sourceforge.net>
  Leigh Wedding <leigh.wedding@telstra.com>
  Tobias Vancura <tvancura@altavista.net>
  James Treacy <treacy@debian.org>
  Bradley Dean <bjdean@bjdean.id.au>
  Erik Colson <eco@ecocode.net>

The Finance::Quote home page can be found at
http://finance-quote.sourceforge.net/

The Finance::YahooQuote home page can be found at
http://www.padz.net/~djpadz/YahooQuote/

The GnuCash home page can be found at
http://www.gnucash.org/

=head1 SEE ALSO

Finance::Quote::AEX,
Finance::Quote::AIAHK,
Finance::Quote::ASEGR,
Finance::Quote::ASX,
Finance::Quote::Bloomberg,
Finance::Quote::BMONesbittBurns,
Finance::Quote::BSEIndia,
Finance::Quote::BSERO,
Finance::Quote::Bourso,
Finance::Quote::CSE,
Finance::Quote::Cdnfundlibrary,
Finance::Quote::Citywire,
Finance::Quote::Cominvest,
Finance::Quote::Currencies,
Finance::Quote::DWS,
Finance::Quote::Deka,
Finance::Quote::FTPortfolios,
Finance::Quote::FTfunds,
Finance::Quote::Fidelity,
Finance::Quote::FidelityFixed,
Finance::Quote::Finanzpartner,
Finance::Quote::Fool,
Finance::Quote::Fundata
Finance::Quote::GoldMoney,
Finance::Quote::HEX,
Finance::Quote::HU,
Finance::Quote::IEXCloud,
Finance::Quote::IndiaMutual,
Finance::Quote::LeRevenu,
Finance::Quote::MStaruk,
Finance::Quote::ManInvestments,
Finance::Quote::Morningstar,
Finance::Quote::MorningstarAU,
Finance::Quote::MorningstarCH,
Finance::Quote::MorningstarJP,
Finance::Quote::NSEIndia,
Finance::Quote::NZX,
Finance::Quote::OnVista,
Finance::Quote::Oslobors,
Finance::Quote::Platinum,
Finance::Quote::SEB,
Finance::Quote::TNetuk,
Finance::Quote::TSP,
Finance::Quote::TSX,
Finance::Quote::Tdefunds,
Finance::Quote::Tdwaterhouse,
Finance::Quote::Tiaacref,
Finance::Quote::Troweprice,
Finance::Quote::Trustnet,
Finance::Quote::USFedBonds,
Finance::Quote::Union,
Finance::Quote::VWD,
Finance::Quote::XETRA,
Finance::Quote::YahooJSON,
Finance::Quote::YahooYQL,
Finance::Quote::ZA,
Finance::Quote::ZA_UnitTrusts

You should have received the Finance::Quote hacker's guide with this package.
Please read it if you are interested in adding extra methods to this package.
The latest hacker's guide can also be found on GitHub at
https://github.com/finance-quote/finance-quote/blob/master/Documentation/Hackers-Guide

=cut
