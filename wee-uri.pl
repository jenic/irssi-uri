#####################################################################
# This script fetches the <title> of a URL posted and prints it
# in WeeChat.
#
# This script is based on the fork of Toni Viemerö's spotifyuri
# script, by Caesar Ahlenhed for irssi. Their websites are below:
# http://spotify.url.fi/
# http://sniker.codebase.nu/
#
# You will need the following packages:
# LWP::UserAgent (You can install this using cpan -i LWP::UserAgent)
# Crypt::SSLeay  (You can install this using cpan -i Crypt::SSLeay)
# 
# Or if you're using Debian GNU/Linux:
# apt-get update;apt-get install libwww-perl libcrypt-ssleay-perl
#
# Script heavily modified by Jenic Rycr, list of changes:
# Support multiple links per line
# Ignore content that is not text/html
# 1MB max download size before giving up
# Stop downloading chunks after <title> tags detected
# detect <title> is now case insensitive (for older <TITLE> tags)
# ignores blacklisted links
# Strips extraneous whitespace from titles before printing 
# Smarter url detection
# Port from irssi to WeeChat
# Code rewrite sufficiently changes this script, relicensed as GPL3
#
#####################################################################

use strict;
use LWP::UserAgent;
use Carp qw(croak);
use HTML::Entities;
use constant _VERSION => sprintf("%s", weechat::info_get('version',''));

my $self = 'uri';
my (%cache, %cacheT);
# Default Options
my %opt =	( 'debug'		=>	0
			, 'xown'		=>	0
			, 'single_nick'	=>	0
			, 'cache'		=>	5
			, 'cachet'		=> 3600
			);

weechat::register	( $self
					, 'Jenic Rycr <jenic\@wubwub.me>'
					, '0.5'
					, 'GPL3'
					, 'URI Title Fetching'
					, ''
					, ''
					);

## URL Blacklist
#  Evaluated as regular expressions
my @blacklist = ( 'blinkenshell\.org'
				, 'xmonad\.org'
				, 'utw\.me'
				);

# Helper Subroutines
sub debug {
	return unless $opt{debug};
	my ($msg, $buffer) = @_;
	my ($s, $m, $h) = (localtime(time) )[0,1,2,3,6];
	my $date = sprintf "%02d:%02d:%02d", $h, $m, $s;
	weechat::print($buffer, "[uri::debug]\t$msg");
	return 1;
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
	my @urljar = ($url =~ /(https?:\/\/(?:[^\s"';]+))/g);
	# Filter out blacklisted links
	@urljar = grep { &chklist($_) } @urljar;
	return (@urljar > 0) ? @urljar : ();
}
sub getNick {
	# WeeChat includes msgs sent by itself in this cb
	return $opt{single_nick} if $opt{single_nick};
	# This code based on expand_uri.pl by Nils Görs
	my $buffer = shift;
	my $infolist = weechat::infolist_get('buffer', $buffer, '');
	weechat::infolist_next($infolist);
	&debug(weechat::infolist_string($infolist, 'name'), $buffer);
	my $server = substr( (split /#/, weechat::infolist_string($infolist, 'name'))[0], 0, -1 );
	weechat::infolist_free($infolist);
	&debug("server: $server", $buffer);
	my $nick = weechat::info_get('irc_nick', $server);
	return $nick;
}

# LWP Handler Subroutines
sub headcheck {
	my ($response, $ua, $h) = @_;
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
    $ua->agent("WeeChat/" . _VERSION . ' ' . $ua->agent());
		$ua->max_size(1024); # max 1MB download
		# add header handler to stop if not html
		$ua->add_handler(response_header => \&headcheck);
		# add data handler to stop after we dl <title>
		$ua->add_handler(response_data => \&titlecheck);
    my $res = $ua->get($data);
		return ($res->is_success) ? $res->content : 0;
}

# Callback Subroutines
sub uri_cb {
	my ($data, $buffer, $date, $tags, $displayed, $highlight, $prefix, $message) = @_;
	&debug(join('::', @_), $buffer);
	my @url = &uri_parse($message);
	# there is no need to go beyond this point otherwise
	return weechat::WEECHAT_RC_OK unless (@url > 0);
	unless($opt{xown}) {
		my $nick = &getNick($buffer);
		&debug("My nick is $nick", $buffer);
		return weechat::WEECHAT_RC_OK if($prefix =~ /.$nick/);
	}
	
	for my $uri (@url) {
		# Check our cache for a recent entry
		if(exists $cache{$uri} && $cacheT{$uri} < (time - $opt{cachet})) {
			weechat::print($buffer, "[uri]\t".$cache{$uri});
			$cacheT{$uri} = time;
			next;
		}
		# No cache entry, get the uri
		my $retval = uri_get($uri);
		if($retval =~ /<title>(.*?)<\/title>/is) {
			$retval = $1;
		} else {
			next;
		}
		&debug("Raw retval = $retval", $buffer);
		# multiple small calls to engine more efficient than expressed in regex
		$retval =~ s/\n//g;
		$retval =~ s/^\s+//;
		$retval =~ s/\s+$//;
		$retval = decode_entities($retval);

		weechat::print($buffer, "[uri]\t$retval");
		# Add this to cache and do some cache pruning
		my $d = (sort keys %cacheT)[0];
		&debug("Cache Prune: " . delete $cache{$d} .':'. delete $cacheT{$d})
			if (scalar keys %cache > $opt{cache});
		$cache{$uri} = $retval;
		$cacheT{$uri} = time;
	}
	return weechat::WEECHAT_RC_OK;
}
sub toggle_opt {
	my ($pointer, $option, $value) = @_;
	my $o = (split /\./, $option)[-1];
	if(exists $opt{$o}) {
		$opt{$o} = $value;
	} else {
		weechat::print(weechat::current_buffer(), "$option doesn't exist!");
	}
	return weechat::WEECHAT_RC_OK;
}
=item test
sub test {
	my ($data, $buffer, $date, $tags, $displayed, $highlight, $prefix, $message) = @_;
	&debug( join('::', @_), $buffer);
	return weechat::WEECHAT_RC_OK;
}
=cut

# Settings
for (keys %opt) {
	if(weechat::config_is_set_plugin($_)) {
		$opt{$_} = weechat::config_get_plugin($_);
	} else {
		weechat::config_set_plugin($_, $opt{$_});
	}
}

weechat::hook_print('', 'notify_message', '://', 1, 'uri_cb', '');
#weechat::hook_print('', 'irc_nick', '', 1, 'test', '');
weechat::hook_config("plugins.var.perl.$self.*", 'toggle_opt', '');
