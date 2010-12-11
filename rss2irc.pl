# rss2irc:  Get news from rss sites and post it into a certain irc
#           channel.
# WRY found this lying around on the net and hacked it a lot.
# Copyright status is unclear, but rewriting it to throw away the
# unclear bits shouldn't be too hard.


#!/usr/bin/perl -w
use strict;
use Net::IRC;
use XML::RSS;
use LWP::UserAgent;
use Carp;
#use Encode;

my $rss = new XML::RSS(encoding=>"UTF-8");
my $irc = new Net::IRC;

my $TEST = 0;

my $t = shift @ARGV;
$TEST=1 if $t eq '--test';

print "Connecting...\n";

my $conn = $irc->newconn(
	Server 		=> 'irc.chiark.greenend.org.uk',
	Port    	=>  6667,
	Nick		=> 'beeb',
	Ircname		=> 'perl',
	Username	=> 'beeb',
	Realname	=> "rss2irc bot",
) unless $TEST==1;

my $checktime = 600; # seconds
my $perfeed = 3; # number of items to report per feed
my $throttle = 3; # seconds between reports

$conn->{channel} = '#beeb';

$conn->{status} = "wait"; # "wait" or "check" states
$conn->{oldtime} = time;
$conn->{newtime} = time;
my $cachedir = "cache/";
my @sites;
my $hupflag = 0;

read_sites();

# SITES FILE FORMAT:
# SITENAME;COLOUR;FEEDURL
# "SITENAME" is the site short name for notifications
# "COLOUR" is an IRC colour code, for clients which support it, from 1-7(?)
# "FEEDURL" is, duh, the feed's URL.

# N.B. Send a SIGUSR1 to force reread.

sub read_sites {
    my $ch;
    my @newsites;
    open($ch, "sites") or die "Cant open configfile: $!";
    while(<$ch>) {
	next if /^#/;
	next if /^\s*$/;
	push(@newsites, [ split /;/ ]);
    }
    @sites = @newsites;
}

#### REPORTING QUEUE
my @to_report = ();
sub push_story($) {
	my $art = shift;
	push @to_report,$art;
}

sub story_next() {
    my $a = shift @to_report;
    return $a;
    # returns undef if queue empty
}


#### IRC HANDLING CODE

sub on_connect {
    my $conn = shift;
    print "Connected!\n";
    $conn->join($conn->{channel}) unless $TEST==1;
    $conn->{status} = "check"; # Auto-report on start. Or maybe this needs to be in a join handler?
}

sub read_news {
    my $conn = shift;
    my $story = story_next();
    $conn->privmsg($conn->{channel},$story) if (defined $story) and $TEST!=1;
}

sub handle_waiting {
    my $conn = shift;
    $conn->{oldtime} = $conn->{newtime};
    $conn->{newtime} = time;
    my $secs = $conn->{newtime} - $conn->{oldtime};
    $conn->{waittime} += $secs;
    if ($conn->{waittime} > $checktime) {
        $conn->{status} = 'check';
        $conn->{waittime} = 0;
    } else {
        $conn->{status} = "wait";
    }

    # Don't flood IRC, we'll get kicked off
    $conn->{readtime} += $secs;
    if ($conn->{readtime} > $throttle) {
        read_news($conn);
        $conn->{readtime} = 0;
    }
}

sub cheat_encode($) {
    # We cheat horribly in the absence of Encode.pm.
    # TODO: Reinstate use of Encode. Perhaps tricky on chiark without a perl upgrade?
    $_=shift;
    s/\xA3/GBP/g; # Pound signs choke some clients
    s/\xA4/EUR/g;
    s/[^ -~]/?/g;
    s/\?\s+//g;
    if (0) {
        # HEXDUMP TEMP:
        print "TEnc: ";
        while (/(.)/g) { printf "%02x", ord($1) }
        print "\n";
    }
    return $_;
}

sub get_news {
    my $conn = shift;
    my ($content,$site,$title,$tmp);
    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    $ua->env_proxy;
    foreach my $item (@sites) {
        my $response = $ua->get($item->[2]);
        if( $response->is_success ) {
            $content = $response->content;
            my $ref = eval {
                local $SIG{'__DIE__'}; # perlfunc: don't trigger the die trap
                $rss->parse($content);
            };
            if($@) {
                print "Error parsing feed ".$item->[0]." (".$item->[2]."): $@\n";
            } else {
                # Report the top N items.
                my @newcache = ();
                for (my $i=0; $i<$perfeed; $i++) {
                    if(!check_cache($item->[0], $rss->{'items'}->[$i]->{'link'}) or $TEST==1) {
                        # XXX Cheesy encoding in the absence of Encode.pm
                        #my $title = Encode::encode("iso-8859-1", $rss->{items}->[$i]->{title});
                        my $title = cheat_encode($rss->{items}->[$i]->{title});

                        #$site  = ''.$item->[1].$item->[0].': ';
                        $site  = ''.$item->[0].': ';
                        #my $tmplink = $rss->{'items'}->[$i]->{'link'};
                        #$tmplink =~ s/^\s+//; $tmplink =~ s/\s+$//;
                        #$tmplink =~ s,^(http://news.bbc.co.uk/)go/rss/-/(.*),$1$2,;
                        #my $link = Encode::encode("iso-8859-1", $tmplink);
                        #my $link = cheat_encode($tmplink);
                        my $link = cheat_encode(url_canon($rss->{'items'}->[$i]->{'link'}));
                        print "Reporting: S=$site T=$title L=$link\n";
                        push_story($site.$title." -> ".$link);
                    } else { print "Cached: ".url_canon($rss->{'items'}->[$i]->{'link'})."\n"; }
                    push @newcache, url_canon($rss->{'items'}->[$i]->{'link'});
                }
                update_cache($item->[0], @newcache);
            }
        } else {
            my $m = "Error fetching page for ".$item->[0].": ".$response->status_line;
            print "$m\n  URL for this was: ".$item->[2]."\n";
            $conn->privmsg($conn->{channel}, $m) unless $TEST==1;
        }
    }
}

sub read_cache($) {
    my ($name) = shift;
    my ($fh, $cachelink);
    my $cachefile = $cachedir."/".$name;
    my @rv;
    return undef if( ! -e $cachefile ); 
    open($fh, $cachefile) or die ("Cant open cachefile: $!");
    while (<$fh>) {
	chomp;
	push @rv, $_;
    }
    close($fh); 
    return @rv;
}

sub url_canon {
  my ($link) = shift;
  $link =~ s/^\s+//; $link =~ s/\s+$//;
  $link =~ s,^(http://www.bbc.co.uk/)go/rss/int/news/-/(.*),$1$2,;
  return $link;
}

sub check_cache {
    my ($name) = shift;
    my ($link) = shift;
    $link = url_canon($link);
    my @c = read_cache($name);
    my $rv = 0;
    for (@c) { $rv=1 if ($_ eq $link) }
    return $rv;
}

sub update_cache {
    my ($name) = shift;
    # args: name, cachelink [,link [,link ...]]
    # so @_ is now the new cache. OVERWRITES what's already there!
    my $fh;
    my $cachefile = $cachedir."/".$name;
    open($fh, ">", $cachefile) or die ("Cant open cachefile: $!");
    print $fh $_.$/ for (@_);
    close($fh);
}

sub check_status {
    my $conn = shift;
    if ($hupflag) {
    	read_sites();
    	$conn->{status} = "check";
        $hupflag = 0;
    }
    if($conn->{status} =~ /^check$/ or $TEST==1) {
        get_news($conn);
        $conn->{waittime} = 0;
        $conn->{status} = "wait";
    } else {
        handle_waiting($conn);
    }
}

my $dead = 0;
sub on_disconnect {
    my ($self, $event) = @_;
    return if $dead;
    print "Disconnected from ", $event->from(), " (",
	  ($event->args())[0], "). Attempting to reconnect...\n";
    $self->connect();
}

sub on_kill {
    my ($self, $event) = @_;
    print "Killed by ircop! (from=", $event->from(), ", arg=",
	  ($event->args())[0], "). Sulking now.\n";
    exit 1;
}

unless ($TEST==1) {
$conn->add_handler('376', \&on_connect);
$conn->add_global_handler('disconnect', \&on_disconnect);
$conn->add_global_handler('kill', \&on_kill);
}

# SIGNAL HANDLERS:
# USR1 = reread sites file and refresh all sites now
$SIG{USR1} = sub {
    $hupflag = 1;
};
sub deathsig {
  my ($sig) = @_;
  print "Caught SIG$sig - leaving\n";
  $dead = 1;
  $conn->quit("Aiee! Killed, in the study, by a SIG$sig.") unless $TEST==1;
  exit 2;
}
sub deathexcept {
  my ($exc) = @_;
  print "fatal exception:\n";
  Carp::cluck($exc);
  $dead = 1;
  $conn->quit("Aiee! Killed, in the drawing room, by an exception most foul.") unless $TEST==1;
  exit 2;
}
$SIG{INT} = \&deathsig;
$SIG{QUIT} = \&deathsig;
$SIG{__DIE__} = \&deathexcept;

while (1) {
    check_status($conn);
    $irc->do_one_loop();
}

