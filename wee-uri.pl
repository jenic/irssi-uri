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
# Complete code rewrite relicensed as GPL3
# Caching Support for frequent urls and to guard against abuse
#
#####################################################################

use strict;
use LWP::UserAgent;
use Carp qw(croak);
use HTML::Entities;

my $self = 'uri';
my (%cache, %cacheT);
my @blacklist;

# Default Options
my %opt =	( 'debug'		=>	0
		, 'xown'		=>	0
		, 'single_nick'		=>	0
		, 'cache'		=>	5
		, 'cachet'		=>	3600
		, 'blfile'		=> $ENV{HOME} . "/.weechat/.uribl"
		);

weechat::register	( $self
			, 'Jenic Rycr <jenic\@wubwub.me>'
			, '0.8'
			, 'GPL3'
			, 'URI Title Fetching'
			, ''
			, ''
			);

my $version = sprintf("%s", weechat::info_get('version',''));

## URL Blacklist
#  Evaluated as regular expressions
sub blup {
	return weechat::WEECHAT_RC_OK unless (-e $opt{blfile});
	open FH, $opt{blfile} or return weechat::WEECHAT_RC_OK;
	my @bl = <FH>;
	chomp @bl;
	close FH;
	@blacklist = @bl;
	return weechat::WEECHAT_RC_OK;
}

# Helper Subroutines
sub debug {
    return unless $opt{debug};
    my $msg = shift;
    weechat::print(weechat::current_buffer(), "[uri::debug]\t$msg");
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
    my $server = substr (	( split /#/
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

# LWP Handler Subroutines
sub headcheck {
    my ($response, $ua, $h) = @_;
    my $v = $response->header('Content-Type');
    croak "complete" unless ($v && $v =~ /text\/html/);
    return 0;
}
sub titlecheck {
    my ($r, $ua, $h, $data) = @_;
    &debug(join('::', @_));
    if (!$r->is_redirect && $data =~ /<title>(?:.*?)<\/title>/is) {
	    debug("title found in chunk, croaking");
	    croak "complete";
    }
    return 1;
}

sub uri_get {
    my ($data) = @_;
    my $ua = LWP::UserAgent->new(env_proxy=>1, keep_alive=>1, timeout=>5);
    $ua->agent("WeeChat/$version " . $ua->agent());
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
    my ($data, $buffer, $date, $tags, $disp, $hl, $prefix, $message) = @_;
    &debug(join('::', @_));
    my @url = &uri_parse($message);
    # there is no need to go beyond this point otherwise
    return weechat::WEECHAT_RC_OK unless (@url > 0);
    unless($opt{xown}) {
	my $nick = &getNick($buffer);
	&debug("My nick is $nick");
	return weechat::WEECHAT_RC_OK if($prefix =~ /.$nick$/);
    }
    
    for my $uri (@url) {
	# Check our cache for a recent entry
	    if(exists $cache{$uri} && ($cacheT{$uri} > (time - $opt{cachet})) ) {
		    weechat::print($buffer, "[uri]\t".$cache{$uri});
		    &debug("Used Cache from " . $cacheT{$uri});
		    $cacheT{$uri} = time;
		    next;
	    }
	    # No cache entry, get the uri
	    my $retval = uri_get($uri);
	    &debug("Raw retval = $retval");
	    if($retval =~ /<title>(.*?)<\/title>/is) {
		    $retval = $1;
	    } else {
		    &debug("Gave up on matching <title>");
		    next;
	    }
	    # multiple small calls to engine more efficient than expressed in regex
	    $retval =~ s/\n//g;
	    $retval =~ s/^\s+//;
	    $retval =~ s/\s+$//;
	    $retval = decode_entities($retval);

	    weechat::print($buffer, "[uri]\t$retval");
	    # Add this to cache and do some cache pruning
	    # This pruning is a fall back incase proper prune fails for w/e reason.
	    # Don't want memory filling up with url's!
	    if (scalar keys %cache > ($opt{cache}*2)) {
		    &debug("Cache Prune Fallback! Something weird happened!");
		    %cache = %cacheT = ();
	    }
	    $cache{$uri} = $retval;
	    $cacheT{$uri} = time;
    }
    # Cache Pruning
    if(scalar keys %cache > $opt{cache}) {
	    my @ordered =	map { $_->[0] } # Undecorate
				sort { $a->[1] <=> $b->[1] } # Sort
				map { [$_, $cacheT{$_}] } # Decorate
				keys %cache;
	    &debug("Sorted Cache: @ordered");
	    if(@url > 1) {
		    my $t = scalar keys %cache;
		    my $n = ($t - $opt{cache});
		    my @trunc = splice(@ordered, 0, $n);
		    &debug("Cache is pruning @trunc (t=$t n=$n)");
		    delete @cache{@trunc};
		    delete @cacheT{@trunc};
	    } else {
		    &debug("Cache is pruning $ordered[0]");
		    delete $cache{$ordered[0]};
		    delete $cacheT{$ordered[0]};
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
	    weechat::print(weechat::current_buffer(), "$option doesn't exist!");
    }
    return weechat::WEECHAT_RC_OK;
}
sub dumpcache {
    weechat::print(weechat::current_buffer(), "[uri]\t$_ ($cache{$_})\n")
	    for (keys %cache);
	    %cache = %cacheT = ();
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

# Load Blacklist
&blup if (-e $opt{blfile});

weechat::hook_print('', 'notify_message', '://', 1, 'uri_cb', '');
weechat::hook_config("plugins.var.perl.$self.*", 'toggle_opt', '');
weechat::hook_command	( $self
			, 'Dumps contents of cache'
			, ""
			, ''
			, ''
			, 'dumpcache'
			, ''
			);
weechat::hook_command	( 'blup'
			, 'Updates Blacklist'
			, ""
			, ''
			, ''
			, 'blup'
			, ''
			);
