#####################################################################
# This script fetches the <title> of a URL posted and prints it
# in WeeChat.
#
# This script is originally based on the fork of Toni Viemerö's
# spotifyuri script, by Caesar Ahlenhed for irssi.
# Their websites are below:
# http://spotify.url.fi/
# http://sniker.codebase.nu/
#
# Requires curl
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
# debug:debugging messages (number > 0 | off)
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
#maxdl:Maximum limit on download (in bytes)
#timeout:Child process execution time limit (in milliseconds)
my %opt =   ( debug         =>  [ 0, 'Show debug messages [int > 0 | off]' ]
            , xown          =>  [ 0, 'Act on own urls [on | off]' ]
            , single_nick   =>  [ 0, 'Skip call to find own nick [str | off]' ]
            , cache         =>  [ 5, 'Number of urls to cache [int]' ]
            , cachet        =>  [ 3600, 'Keep cached for n seconds [int]' ]
            , blfile        =>  [ $ENV{HOME} . "/.weechat/.uribl"
                                , 'Full path to blacklist file (string)'
                                ]
            , mode          =>  [ 0, 'Mode of operation [see script comments]' ]
            , window        =>  [ $self
                                , 'Name of buffer used for modes > 0 [int]'
                                ]
            , maxdl         =>  [ 1e6, 'Max limit on download, in bytes [int]' ]
            , timeout       =>  [ 9001
                                , 'Child execution time, milliseconds [int]'
                                ]
            , ignore        =>  [ '', 'List of buffers to ignore [str]' ]
            , ua            =>  [ 'Mozilla/4.0', 'Curl\'s declared UA' ]
            );

weechat::register   ( $self
                    , 'Jenic Rycr <jenic\@wubwub.me>'
                    , '1.4'
                    , 'GPL3'
                    , 'URI Title Fetching'
                    , ''
                    , ''
                    );

my $version = weechat::info_get('version_number','');

# Helper Subroutines
sub debug {
    return unless $opt{debug};
    my ($msg, $lvl) = (@_);
    return if ( $lvl && $opt{debug} < $lvl);
    weechat::print(weechat::current_buffer(), "[uri::debug]\t$msg");
    return 1;
}

## Time Sorting
sub tsort {
    return  map { $_->[0] } # Undecorate
            sort { $a->[1] <=> $b->[1] } # Sort
            map { [$_, $cache{$_}->{t}] } # Decorate
            keys %cache;
}

## BL check
sub chklist {
    my $link = shift;
    my $r = 1;
    for my $exp (@blacklist) {
        if ($link =~ $exp) {
            &debug("[BL] $link = $exp", 2);
            $r = 0;
            last;
        }
    }
    return $r;
}

# Grab urls off line and return in urljar array reference
sub uri_parse {
    my ($url) = @_;
    my @urljar = ($url =~ m{(https?://[A-z0-9+&@#/%=~_.-]+)}g);
    # Filter out blacklisted links
    @urljar = grep { &chklist($_) } @urljar;
    # Remove extraneous slashes
    @urljar = map { s/(\/|\#.*)$//;$_; } @urljar;
    return (@urljar > 0) ? \@urljar : [];
}

sub getNick {
    # WeeChat includes msgs sent by itself in this cb
    return $opt{single_nick} if $opt{single_nick};
    # This code based on expand_uri.pl by Nils Görs
    my $buffer = shift;
    my $infolist = weechat::infolist_get('buffer', $buffer, '');
    weechat::infolist_next($infolist);
    &debug(weechat::infolist_string($infolist, 'name'));
    my $server = substr ( ( split /#/
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
    return 0 if(exists $cache{$uri}); # a process is already running
    $cache{$uri} = ();
    $cache{$uri}->{t} = 0;
    $cache{$uri}->{u} = '{PLACEHOLDER}';
    $cache{$uri}->{b} = $buf;

    # This is gross and needs to be done in a better way.
    # *1 to allow perlisms such as 1e6
    # /2000 to convert timeout from millisecond to seconds and cut in half
    my $c = 'curl --max-filesize ' .
        ($opt{maxdl}*1) .
        ' -m ' .
        int($opt{timeout}/2000) .
        " -A '$opt{ua}' -Ls '$uri'";
    &debug("Hooking process for $uri");
    weechat::hook_process($c, $opt{timeout}, 'uri_process_cb', "@_");
    return 1;
}

# Callback Subroutines
sub uri_process_cb {
    my ($data, $cmd, $rc, $stdout, $stderr) = @_;
    &debug(join('||',@_), 2);
    my ($title, $out, $format);
    my ($uri, $buffer, $bufname) = split ' ', $data;
    return weechat::WEECHAT_RC_OK
        if (exists $cache{$uri} && $cache{$uri}->{t});

    if($opt{mode}) {
        $out = $uribuf;
        $format = "$bufname\t%s <%s>";
    } else {
        $out = $buffer;
        $format = "[uri]\t%s";
    }
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
    $title =~ s/[\r\n]+//g;
    $title =~ s/\s+/ /g;
    $title =~ s/(^\s+|\s+$)//;
    $title = decode_entities($title);

    weechat::print($out, sprintf($format, $title, $uri));
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
    $cache{$uri}->{b} = weechat::buffer_get_string($buffer, 'short_name');

    return weechat::WEECHAT_RC_OK;
}

sub uri_cb {
    my ($data, $buffer, $date, $tags, $disp, $hl, $prefix, $msg) = @_;
    my ($out, $format);

    # Before we determine anything, should we ignore this buffer?
    my $bufname = weechat::buffer_get_string($buffer, 'short_name');
    # Ignore urls from ignored buffers
    return weechat::WEECHAT_RC_OK
        if ($opt{ignore} && exists $opt{ignore}->{$bufname});

    if($opt{mode}) {
        $out = $uribuf;
        $format = "[uri]\t%s <%s>";
    } else {
        $out = $buffer;
        $format = "[uri]\t%s";
    }
    my @url = @{uri_parse($msg)};
    &debug("Given urls: @url");

    &debug(join('::', @_), 2);
    # there is no need to go beyond this point otherwise
    return weechat::WEECHAT_RC_OK unless (@url > 0);
    
    unless($opt{xown}) {
        my $nick = getNick($buffer);
        &debug("My nick is $nick");
        return weechat::WEECHAT_RC_OK if($prefix =~ /.$nick$/);
    }
    
    for my $uri (@url) {
        # Check our cache for a recent entry
        if( exists $cache{$uri}
            && ($cache{$uri}->{t} > ($date - $opt{cachet}))
        ) {
            weechat::print($out,
                sprintf($format, $cache{$uri}->{u}, $uri));
            weechat::print($buffer,
                sprintf("[uri]\t%s", $cache{$uri}->{u})
            ) if ($opt{mode} == 2);

            &debug("Used Cache from " . $cache{$uri}->{t});
            $cache{$uri}->{t} = $date;
            next;
        }

        # No cache entry, get the uri
        &debug("Call to uri_get($uri, $buffer, $bufname)");
        uri_get($uri, $buffer, $bufname);
    }
    
    # Cache Pruning
    if(scalar keys %cache > $opt{cache}) {
        my @ordered = &tsort;
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

## URL Blacklist
###  Evaluated as regular expressions
sub blup {
    return weechat::WEECHAT_RC_OK unless (-e $opt{blfile});
    open FH, $opt{blfile} or return weechat::WEECHAT_RC_OK;
    my @bl = <FH>;
    close FH;
    chomp @bl;
    &debug("bl = @bl");
    @blacklist = () if (@bl > 0);
    push @blacklist, qr{$_}i for (@bl);
    weechat::print('', "$self loaded ".@blacklist.' items to BL');
    return weechat::WEECHAT_RC_OK;
}

sub opt_cb {
    my ($pointer, $option, $value) = @_;
    &debug("opt_cb has: @_");
    my $o = (split /\./, $option)[-1];

    unless (exists $opt{$o}) {
        weechat::print('', "$option doesn't exist!");
        return weechat::WEECHAT_RC_ERROR;
    }

    # ignore is a special case
    if ($o eq 'ignore') {
        unless ($value) {
            &debug("Clearing ignore hash", 2);
            $opt{ignore} = undef;
            return weechat::WEECHAT_RC_OK;
        }
        &debug("opt_cb setting $value to ignore", 2);
        $opt{ignore} = { map { $_ => undef } split(',', $value) };
        return weechat::WEECHAT_RC_OK;
    }

    # Normal case
    $opt{$o} = $value;

    return weechat::WEECHAT_RC_OK;
}

sub dumpcache {
    my @sorted = &tsort;
    weechat::print  (''
                    , sprintf   ( "[uri]\t%s (%s) %s [%s]\n"
                                , $cache{$_}->{u}
                                , $_
                                , $cache{$_}->{b}
                                , $cache{$_}->{t}
                                )
                    ) for (@sorted);
    %cache = ();
    return weechat::WEECHAT_RC_OK;
}

sub buff_close {
    $opt{mode} = 0;
    return weechat::WEECHAT_RC_OK;
}

# Settings
# TODO: New weechat api allows typecasting?
while ( my($k, $v) = each %opt ) {
    if (weechat::config_is_set_plugin($k)) {
        if ($version >= 0x00030500) {
            weechat::config_set_desc_plugin($k, $v->[1] || '' .
                " (default: $v->[0])");
        }
        # This will strip the anonymous array since:
        # a) we are storing it using config_set_desc_plugin() and this is
        # redundant or
        # b) we don't support descriptions anyway so why store
        # them during runtime?
        $opt{$k} = weechat::config_get_plugin($k);
    } else {
        weechat::config_set_plugin($k, $v->[0]);
        if ($version >= 0x00030500) {
            weechat::config_set_desc_plugin($k, $v->[1] || '' .
                " (default: $v->[0])");
        }
        # Don't store descriptions during runtime
        $opt{$k} = $v->[1];
    }
}

# Optimize ignore lookups using hash table

if ($opt{ignore}) {
    $opt{ignore} = { map { $_ => undef } split(',', $opt{ignore}) };
    &debug("Ignoring buffer $_") for keys (%{$opt{ignore}});
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
weechat::hook_config("plugins.var.perl.$self.*", 'opt_cb', '');
weechat::hook_command   ( "${self}_dump"
                        , 'Dumps contents of cache'
                        , ''
                        , ''
                        , ''
                        , 'dumpcache'
                        , ''
                        );
weechat::hook_command   ( "${self}_update"
                        , 'Updates Blacklist'
                        , ''
                        , ''
                        , ''
                        , 'blup'
                        , ''
                        );
