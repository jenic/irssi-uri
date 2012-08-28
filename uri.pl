#####################################################################
# This script fetches the <title> of a URL posted and prints it
# in irssi.
#
# This script is basically forked from Toni Viemerö spotifyuri
# script, only slightly modified. You can find his website on 
# http://spotify.url.fi/
#
#
# You will need the following packages:
# LWP::UserAgent (You can install this using cpan -i LWP::UserAgent)
# Crypt::SSLeay  (You can install this using cpan -i Crypt::SSLeay)
# 
# Or if you're using Debian GNU/Linux:
# apt-get update;apt-get install libwww-perl libcrypt-ssleay-perl
#
# UPDATE!
# Script heavily modified by Jenic Rycr, list of changes:
# Support multiple links per line
# Ignore content that is not text/html
# 1MB max download size before giving up
# Stop downloading chunks after <title> tags detected
# detect <title> is now case insensitive (for older <TITLE> tags)
# ignores blacklisted links
# Strips extraneous whitespace from titles before printing to irssi
# Smarter url detection
#
#####################################################################

use strict;
use Irssi;
use Irssi::Irc;
use LWP::UserAgent;
use Carp qw(croak);
use vars qw($VERSION %IRSSI);
use HTML::Entities;

$VERSION = '0.5';
%IRSSI = (
    authors     => 'Caesar "sniker" Ahlenhed',
    contact     => 'sniker@se.linux.org',
    name        => 'uri',
    description => 'Show titles of URLs posted',
    license     => 'BSD',
    url         => 'http://sniker.codebase.nu/',
);

## URL Blacklist
#  Evaluated as regular expressions
my @blacklist = ( 'blinkenshell\.org'
				, 'xmonad\.org'
				, 'utw\.me'
				);
=item maybe_later

sub setc () {
	$IRSSI{'name'}
}
sub set ($) {
	setc . '_' . shift
}

=cut
sub uri_public {
    my ($server, $data, $nick, $mask, $target) = @_;
		my @url = uri_parse($data);
		#Irssi::print("[Debug] uri_public @url : " . scalar @url);
		# there is no need to go beyond this point otherwise, //jenic
		return 0 unless (@url > 0);
		my $win = $server->window_item_find($target);
		for my $uri (@url) {
			my $retval = uri_get($uri);
			#Irssi::print("[Debug] $uri : $?");
			if($retval =~ /<title>(.*?)<\/title>/is) {
				$retval = $1;
			} else {
				next;
			}
			$retval =~ s/\n//g;
			#multiple small calls to engine more efficient than expressed in regex
			$retval =~ s/^\s+//;
			$retval =~ s/\s+$//;
			$retval = decode_entities($retval);
			
			next unless ($retval);
			( ($win) ?
				$win->print($retval, MSGLEVEL_CRAP) :
				Irssi::print($retval)
			);
		}
}
sub uri_private {
    my ($server, $data, $nick, $mask) = @_;
		my @url = uri_parse($data);
		#Irssi::print("[Debug] uri_public @url : " . scalar @url);
		# there is no need to go beyond this point otherwise, //jenic
		return 0 unless (@url > 0);
		my $win = $server->window_item_find($nick);
		for my $uri (@url) {
			my $retval = uri_get($uri);
			#Irssi::print("[Debug] $uri : $?");
			if($retval =~ /<title>(.*?)<\/title>/is) {
				$retval = $1;
			} else {
				next;
			}
			$retval =~ s/\n//g;
			$retval =~ s/^\s+//;
			$retval =~ s/\s+$//;
			$retval = decode_entities($retval);
			
			next unless ($retval);
			( ($win) ?
				$win->print($retval, MSGLEVEL_CRAP) :
				Irssi::print($retval)
			);
		}
}

sub chklist {
	my $link = shift;
	my $r = 1;
	for my $exp (@blacklist) {
		if ($link =~ /$exp/) {
			$r = 0;
			last;
		}
	}
	return $r;
}

sub uri_parse {
	my ($url) = @_;
	#Irssi::print("[Debug] uri_parse: $url");
	my @urljar = ($url =~ /(https?:\/\/(?:[^\s"';]+))/g);
	# Filter out blacklisted links
	@urljar = grep { &chklist($_) } @urljar;
	return (@urljar > 0) ? @urljar : ();
}

sub headcheck {
	my ($response, $ua, $h) = @_;
	#Irssi::print("[Debug] header: " . $response->header("Content-Type"));
	croak "complete" unless ($response->header('Content-Type') =~ /text\/html/);
	return 0;
}
sub titlecheck {
	my ($response, $ua, $h, $data) = @_;
	croak "complete" if ($data =~ /<title>(?:.*?)<\/title>/is);
	return 1;
}

sub uri_get {
    my ($data) = @_;
    my $ua = LWP::UserAgent->new(env_proxy=>1, keep_alive=>1, timeout=>5);
    $ua->agent("irssi/$VERSION " . $ua->agent());
		$ua->max_size(1024); # max 1MB download, //jenic
		# add header handler to stop if not html, //jenic
		$ua->add_handler(response_header => \&headcheck);
		# add data handler to stop after we dl <title>, //jenic
		$ua->add_handler(response_data => \&titlecheck);
    my $res = $ua->get($data);
		#Irssi::print("[Debug] uri_get: " . $res->is_success . "::" . $res->content);
		return ($res->is_success) ? $res->content : 0;
}

Irssi::signal_add_last('message public', 'uri_public');
Irssi::signal_add_last('message private', 'uri_private');

#Irssi::settings_add_int(setc, set 'maxdl', 1024);
