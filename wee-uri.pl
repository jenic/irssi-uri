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
# Or if you're using Debian:
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
# Complete code rewrite relicensed as GPL3
# Caching Support for frequent urls and to guard against abuse
# Weechat's hook_process to prevent I/O blocking
#
#####################################################################

use strict;
use HTML::Entities qw(decode_entities);

my $self = 'uri';
my $uribuf;
my %cache;
my @blacklist;

# Default Options
# debug:debugging messages (on | off)
# xown:process links from self (on | off)
# single_nick:staticly set your nick (string | off)
# cache:how many entries to cache (number)
# cachet:Keep cache for n seconds (number)
# blfile:full path of blacklist file (file)
# mode:operation mode (number)
## 0 = Print in current buffer
## 1 = Print in dedicated buffer
## 2 = Both 0 & 1
#window:name of buffer to print in for mode 1&2 (string)
my %opt =	( 'debug'		=> 0
		, 'xown'		=> 0
		, 'single_nick'		=> 0
		, 'cache'		=> 5
		, 'cachet'		=> 3600
		, 'blfile'		=> $ENV{HOME} . "/.weechat/.uribl"
		, 'mode'		=> 0
		, 'window'		=> $self
		);

weechat::register	( $self
			, 'Jenic Rycr <jenic\@wubwub.me>'
			, '1.0'
			, 'GPL3'
			, 'URI Title Fetching'
			, ''
			, ''
			);

my $version = sprintf("%s", weechat::info_get('version',''));

# Helper Subroutines
sub debug {
	return unless $opt{debug};
	my $msg = shift;
	weechat::print(weechat::current_buffer(), "[uri::debug]\t$msg");
	return 1;
}
## URL Blacklist
###  Evaluated as regular expressions
sub blup {
	return weechat::WEECHAT_RC_OK unless (-e $opt{blfile});
	open FH, $opt{blfile} or return weechat::WEECHAT_RC_OK;
	my @bl = <FH>;
	chomp @bl;
	close FH;
	@blacklist = @bl;
	return weechat::WEECHAT_RC_OK;
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
	my @urljar = ($url =~ m{(https?://(?:[^\s"';]+))}g);
	# Filter out blacklisted links
	@urljar = grep { &chklist($_) } @urljar;
	# Remove extraneous slashes
	@urljar = map { s/\/$//;$_; } @urljar;
	return (@urljar > 0) ? @urljar : ();
}
sub getNick {
	# WeeChat includes msgs sent by itself in this cb
	return $opt{single_nick} if $opt{single_nick};
	# This code based on expand_uri.pl by Nils Görs
	my $buffer = shift;
	my $infolist = weechat::infolist_get('buffer', $buffer, '');
	weechat::infolist_next($infolist);
	&debug(weechat::infolist_string($infolist, 'name'));
	my $server = substr	(	( split /#/
					, weechat::infolist_string($infolist, 'name')
					)[0]
				, 0
				, -1
				);
	weechat::infolist_free($infolist);
	&debug("server: $server");
	my $nick = weechat::info_get('irc_nick', $server);
	return $nick;
}

# Where the magic happens
sub uri_get {
	my ($uri, $buf) = @_;
	my $c = 'perl -MLWP::UserAgent -MCarp -e\'' .
	'sub hc{my($r,$u,$h)=@_;my $v=$r->header("Content-Type");croak "complete" if($v && $v !~ /text\/html/);return 0;}' .
	'sub tc{my($r,$u,$h,$d)=@_;if(!$r->is_redirect && $d=~/<title>.*<\/title>/is){croak "complete";}return 1;}' .
	'my $d=q(http://google.com);system(q(touch ~/test);my $u=LWP::UserAgent->new(env_proxy=>1,keep_alive=>1,timeout=>8);$u->max_size(1024);' .
	'$u->add_handler(response_header=>*hc{CODE});$u->add_handler(response_data=>*tc{CODE});' .
	'my $r=$u->get($d);print(($r->is_success)?$r->content:0);';
	&debug("Hooking process for $uri");
	weechat::hook_process($c, 10000, 'uri_process_cb', "@_");
	return 1;
}
# Callback Subroutines
sub uri_process_cb {
	my ($data, $cmd, $rc, $stdout, $stderr) = @_;
	&debug(join('||',@_));
	my $title;
	my ($uri, $buffer) = split ' ', $data;
	my $out = ($opt{mode}) ? $uribuf : $buffer;
	if($stdout =~ /<title>(.*?)<\/title>/is) {
		if(!$1) {
			&debug("Pattern matched but title empty");
			return weechat::WEECHAT_RC_OK;
		}
		$title = $1;
	} else {
		&debug("Gave up on matching <title>");
		return weechat::WEECHAT_RC_OK;
	}

	# multiple small calls to engine more efficient than expressed in regex
	$title =~ s/[\r\n]//g;
	$title =~ s/\s+/ /g;
	$title = decode_entities($title);

	weechat::print($out, "[uri]\t$uri ($title)");
	weechat::print($buffer, "[uri]\t$title")
		if ($opt{mode} == 2);
	# Add this to cache and do some cache pruning
	# This pruning is a fall back incase proper prune fails for w/e reason.
	# Don't want memory filling up with url's!
	if (scalar keys %cache > ($opt{cache}*2)) {
		&debug("Cache Prune Fallback! Something weird happened!");
		%cache = ();
	}
	$cache{$uri}->{u} = $title;
	$cache{$uri}->{t} = time;

	return weechat::WEECHAT_RC_OK;
}
sub uri_cb {
	my ($data, $buffer, $date, $tags, $disp, $hl, $prefix, $msg) = @_;
	my $out = ($opt{mode}) ? $uribuf : $buffer;
	my @url = &uri_parse($msg);

	&debug(join('::', @_));
	# there is no need to go beyond this point otherwise
	return weechat::WEECHAT_RC_OK unless (@url > 0);
	
	unless($opt{xown}) {
		my $nick = &getNick($buffer);
		&debug("My nick is $nick");
		return weechat::WEECHAT_RC_OK if($prefix =~ /.$nick$/);
	}
    
	for my $uri (@url) {
		# Check our cache for a recent entry
		if(exists $cache{$uri} && ($cache{$uri}->{t} > ($date - $opt{cachet}))) {
			weechat::print($out, "[uri]\t$uri (".$cache{$uri}->{u}.')');
			weechat::print($buffer, "[uri]\t".$cache{$uri}->{u})
				if ($opt{mode} == 2);
			&debug("Used Cache from " . $cache{$uri}->{t});
			$cache{$uri}->{t} = $date;
			next;
		}

		# No cache entry, get the uri
		uri_get($uri, $buffer);
	}
	
	# Cache Pruning
	if(scalar keys %cache > $opt{cache}) {
		my @ordered =	map { $_->[0] } # Undecorate
				sort { $a->[1] <=> $b->[1] } # Sort
				map { [$_, $cache{$_}->{t}] } # Decorate
				keys %cache;
		&debug("Sorted Cache: @ordered");
		if(@url > 1) {
			my $t = scalar keys %cache;
			my $n = ($t - $opt{cache});
			my @trunc = splice(@ordered, 0, $n);
			&debug("Cache is pruning @trunc (t=$t n=$n)");
			delete @cache{@trunc};
		} else {
			&debug("Cache is pruning $ordered[0]");
			delete $cache{$ordered[0]};
		}
	}

	return weechat::WEECHAT_RC_OK;
}

sub toggle_opt {
	my ($pointer, $option, $value) = @_;
	my $o = (split /\./, $option)[-1];
	if(exists $opt{$o}) {
		$opt{$o} = $value;
	} else {
		weechat::print('', "$option doesn't exist!");
	}
	return weechat::WEECHAT_RC_OK;
}
sub dumpcache {
	weechat::print('', "[uri]\t$_ ($cache{$_}->{u})\n")
		for (keys %cache);
	%cache = ();
	return weechat::WEECHAT_RC_OK;
}
sub buff_close {
	$opt{mode} = 0;
	return weechat::WEECHAT_RC_OK;
}

# Settings
for (keys %opt) {
	if(weechat::config_is_set_plugin($_)) {
		$opt{$_} = weechat::config_get_plugin($_);
	} else {
		weechat::config_set_plugin($_, $opt{$_});
	}
}

&blup; # Load Blacklist

# Do we need to create a buffer?
$uribuf = weechat::info_get($opt{window}, '') || 0;
if ($opt{mode} > 0 && !$uribuf) {
	debug('Building dedicated buffer named: ' . $opt{window});
	$uribuf = weechat::buffer_new($opt{window}, '', '', "buff_close", '');
	weechat::buffer_set($uribuf, "title", $opt{window});
}

weechat::hook_print('', 'notify_message', '://', 1, 'uri_cb', '');
weechat::hook_config("plugins.var.perl.$self.*", 'toggle_opt', '');
weechat::hook_command	( "${self}_dump"
			, 'Dumps contents of cache'
			, ''
			, ''
			, ''
			, 'dumpcache'
			, ''
			);
weechat::hook_command	( "${self}_update"
			, 'Updates Blacklist'
			, ''
			, ''
			, ''
			, 'blup'
			, ''
			);
