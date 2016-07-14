This is an IRC bot which reads news from RSS and announces it into a
configurable IRC channel. It's specifically adapted for the BBC news feeds.

Configure it by setting your IRC server's hostname in the Server line near the
top. Then edit `sites.test` and run the bot in test mode:
    `./rss2irc.pl --test`

When you're happy, copy `sites.test` over `sites` and run the bot for real:
    `./rss2irc.pl`

The sites file format is documented in comments near the top of the script.
Once in a while, RSS sites get reconfigured and the parsing breaks.
When that happens, I tend to use Dumper to output what I'm actually reading
from the site and tweak the parser (in `get_news`) until it works again.

