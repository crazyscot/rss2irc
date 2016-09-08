#!/usr/bin/perl -w -I/home/ryounger/beeb2
# rss2irc:  Get news from rss sites and post it into a certain irc
#           channel.
#
# Written by Ross Younger, but drawing heavily on example code and
# other similar projects.


use strict;
use Net::IRC;
use XML::RSS;
use LWP::UserAgent;
use Carp;
#use Encode;
use Data::Dumper;

my $rss = new XML::RSS(encoding=>"UTF-8");
my $irc = new Net::IRC;

my $TEST = 0;
my $SITESFILE = "sites";
my $CACHEDIR = "cache/";

###### For testing, run with --test

my $t = shift @ARGV;
if ($t eq '--test') {
    $TEST=1;
    $SITESFILE = "sites.test";
    $CACHEDIR = "cache.test/";
}

print "Connecting...\n";

my $conn = $irc->newconn(
	Server 		=> 'YOUR-IRC-SERVER-HERE',
	Port    	=>  6667,
	Nick		=> 'beeb',
	Ircname		=> 'perl',
	Username	=> 'beeb',
	Realname	=> "rss2irc bot",
) unless $TEST==1;

my $checktime = 600; # seconds
my $perfeed = 4; # number of items to report per feed
my $throttle = 3; # seconds between reports

$conn->{status} = "wait"; # "wait" or "check" states
$conn->{oldtime} = time;
$conn->{newtime} = time;
mkdir $CACHEDIR unless -d $CACHEDIR;
my @sites;
my $hupflag = 0;

read_sites();

# SITES FILE FORMAT:
# CHANNEL;SITENAME;COLOUR;FEEDURL
# CHANNEL is what to join (no leading '#' !)
# "SITENAME" is the site short name for notifications
# "COLOUR" is an IRC colour code, for clients which support it, from 1-7(?)
# "FEEDURL" is, duh, the feed's URL.

# N.B. Send a SIGUSR1 to force reread.

sub read_sites {
    my $ch;
    my @newsites;
    open($ch, $SITESFILE) or die "Cant open configfile: $!";
    while(<$ch>) {
	next if /^#/;
	next if /^\s*$/;
	push(@newsites, [ split /;/ ]);
    }
    @sites = @newsites;
}

#### REPORTING QUEUE
my @to_report = ();
sub push_story($$) {
	my ($chan,$line) = @_;
    my %story = ();
    $story{channel} = $chan;
    $story{story} = $line;
    push @to_report, \%story;
    #push @to_report,$art;
}

sub story_next() {
    my $a = shift @to_report;
    return $a;
    # returns undef if queue empty
}


#### IRC HANDLING CODE

my %chans = ();

sub on_connect {
    my $conn = shift;
    print "Connected!\n";
    foreach my $site (@sites) {
        my $c = '#'.$site->[0];
        unless ($TEST==1 or exists $chans{$c}) {
            print "Joining $c\n";
            $conn->join($c);
        }
        $chans{$c} = 1;
    }
    $conn->{status} = "check"; # Auto-report on start. Or maybe this needs to be in a join handler?
}

sub read_news {
    my $conn = shift;
    my $story = story_next();
    $conn->privmsg($story->{channel},$story->{story}) if (defined $story) and $TEST!=1;
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
    # TODO: Reinstate use of Encode. Depends on local perl install.
    $_=shift;
    s/\xA3/GBP/g; # Pound signs choke some clients
    s/\xA4/EUR/g;
    s/\xB0//g; # Degree
    s/\n//g; # grr crlf
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
    my $date = `date`;
    chomp $date;
    print "$date: ";
    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    $ua->env_proxy;
    foreach my $site (@sites) {
        my ($content,$tag,$title,$tmp);
        my $response = $ua->get($site->[3]);
        if( $response->is_success ) {
            $content = $response->content;
            my $ref = eval {
                # perlfunc: don't trigger the die trap
                local $SIG{'__DIE__'};
                $rss->parse($content);
            };
            if($@) {
                my $m = "Error parsing feed ".$site->[1]." (".$site->[3]."): $@\n";
                print "$m\n";
                $conn->privmsg('#'.$site->[0], $m) unless $TEST==1;
                # 20120705: Does the RSS object get scroggled on a parse fail? Try resetting it.
                $rss = new XML::RSS(encoding=>"UTF-8");
            } else {
                # Report the top N items.
                my @newcache = ();
                for (my $i=0; $i<$perfeed; $i++) {
                    my $link = url_canon($rss->{'items'}->[$i]->{'link'});
                    #print Dumper(\$rss);
                    if(!check_cache($site->[1], $link) or $TEST==1) {
                        # Cheesy encoding in the absence of Encode.pm
                        #my $title = Encode::encode("iso-8859-1", $rss->{items}->[$i]->{title});
                        my $title = cheat_encode($rss->{'items'}->[$i]->{title});
                        next unless $title ne "";

                        if ($TEST) {
                            $tag = '('.$site->[0].') '.$site->[1].': ';
                        } else {
                            $tag = ''.$site->[2].$site->[1].': ';
                        }
                        #my $tmplink = $rss->{'items'}->[$i]->{'guid'};
                        #$tmplink =~ s/^\s+//; $tmplink =~ s/\s+$//;
                        #$tmplink =~ s,^(http://news.bbc.co.uk/)go/rss/-/(.*),$1$2,;
                        #my $link = Encode::encode("iso-8859-1", $tmplink);
                        #my $link = cheat_encode($tmplink);
                        $link = cheat_encode($link);
                        print "Reporting: S=$tag T=$title L=$link\n";
                        push_story('#'.$site->[0], $tag.$title." -> ".$link);
                    } else { print "Cached: $link\n"; }
                    push @newcache, $link;
                }
                update_cache($site->[1], @newcache);
            }
        } else {
            my $m = "Error fetching page for ".$site->[1].": ".$response->status_line;
            print "$m\n  URL for this was: ".$site->[3]."\n";
            $conn->privmsg('#'.$site->[0], $m) unless $TEST==1;
        }
    }
}

sub read_cache($) {
    my ($name) = shift;
    my ($fh, $cachelink);
    my $cachefile = $CACHEDIR."/".$name;
    my @rv;
    return undef if( ! -e $cachefile ); 
    open($fh, $cachefile) or die ("Can't open cachefile: $!");
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
    my $cachefile = $CACHEDIR."/".$name;
    open($fh, ">", $cachefile) or die ("Can't open cachefile: $!");
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
    sleep $checktime if $TEST;
}

