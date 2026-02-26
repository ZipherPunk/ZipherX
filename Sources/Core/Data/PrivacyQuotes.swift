import Foundation

/// Famous privacy quotes from cypherpunks and Satoshi Nakamoto
struct PrivacyQuotes {
    static let quotes: [(quote: String, author: String)] = [
        // Eric Hughes - A Cypherpunk's Manifesto (1993)
        ("Privacy is necessary for an open society in the electronic age.", "Eric Hughes"),
        ("Privacy is not secrecy. A private matter is something one doesn't want the whole world to know, but a secret matter is something one doesn't want anybody to know.", "Eric Hughes"),
        ("Privacy is the power to selectively reveal oneself to the world.", "Eric Hughes"),
        ("We must defend our own privacy if we expect to have any.", "Eric Hughes"),
        ("Cypherpunks write code.", "Eric Hughes"),
        ("We know that software can't be destroyed and that a widely dispersed system can't be shut down.", "Eric Hughes"),
        ("We must come together and create systems which allow anonymous transactions to take place.", "Eric Hughes"),
        ("We the Cypherpunks are dedicated to building anonymous systems.", "Eric Hughes"),
        ("We are defending our privacy with cryptography, with anonymous mail forwarding systems, with digital signatures, and with electronic money.", "Eric Hughes"),
        ("For privacy to be widespread it must be part of a social contract.", "Eric Hughes"),
        ("An anonymous system empowers individuals to reveal their identity when desired and only when desired; this is the essence of privacy.", "Eric Hughes"),
        ("Cryptography will ineluctably spread over the whole globe, and with it the anonymous transactions systems that it makes possible.", "Eric Hughes"),

        // Timothy C. May - The Crypto Anarchist Manifesto (1992)
        ("Just as the technology of printing altered and reduced the power of medieval guilds and the social power structure, so too will cryptologic methods fundamentally alter the nature of corporations and of government interference in economic transactions.", "Timothy C. May"),
        ("The State will of course try to slow or halt the spread of this technology, citing national security concerns, use of the technology by drug dealers and tax evaders, and fears of societal disintegration.", "Timothy C. May"),
        ("Arise, you have nothing to lose but your barbed wire fences!", "Timothy C. May"),

        // Satoshi Nakamoto
        ("The root problem with conventional currency is all the trust that's required to make it work.", "Satoshi Nakamoto"),
        ("The central bank must be trusted not to debase the currency, but the history of fiat currencies is full of breaches of that trust.", "Satoshi Nakamoto"),
        ("Banks must be trusted to hold our money and transfer it electronically, but they lend it out in waves of credit bubbles with barely a fraction in reserve.", "Satoshi Nakamoto"),
        ("We have to trust them with our privacy, trust them not to let identity thieves drain our accounts.", "Satoshi Nakamoto"),
        ("The possibility to be anonymous or pseudonymous relies on you not revealing any identifying information about yourself in connection with the bitcoin addresses you use.", "Satoshi Nakamoto"),
        ("For greater privacy, it's best to use bitcoin addresses only once.", "Satoshi Nakamoto"),
        ("If you don't believe it or don't get it, I don't have the time to try to convince you, sorry.", "Satoshi Nakamoto"),
        ("Lost coins only make everyone else's coins worth slightly more. Think of it as a donation to everyone.", "Satoshi Nakamoto"),
        ("I've been working on a new electronic cash system that's fully peer-to-peer, with no trusted third party.", "Satoshi Nakamoto"),
        ("What is needed is an electronic payment system based on cryptographic proof instead of trust.", "Satoshi Nakamoto"),

        // Phil Zimmermann (PGP creator)
        ("If privacy is outlawed, only outlaws will have privacy.", "Phil Zimmermann"),
        ("Privacy is an inherent human right, and a requirement for maintaining the human condition with dignity and respect.", "Phil Zimmermann"),

        // Julian Assange
        ("Privacy for the weak, transparency for the powerful.", "Julian Assange"),
        ("Cryptography is the ultimate form of non-violent direct action.", "Julian Assange"),

        // John Perry Barlow
        ("Relying on the government to protect your privacy is like asking a peeping tom to install your window blinds.", "John Perry Barlow"),

        // Bruce Schneier
        ("Privacy is not something that I'm merely entitled to, it's an absolute prerequisite.", "Bruce Schneier"),
        ("If you think technology can solve your security problems, then you don't understand the problems and you don't understand the technology.", "Bruce Schneier"),
        ("Security is a process, not a product.", "Bruce Schneier"),

        // Edward Snowden
        ("Arguing that you don't care about the right to privacy because you have nothing to hide is no different than saying you don't care about free speech because you have nothing to say.", "Edward Snowden"),
        ("Privacy isn't about something to hide. Privacy is about something to protect.", "Edward Snowden"),

        // Hal Finney
        ("Bitcoin seems to be a very promising idea.", "Hal Finney"),
        ("Running bitcoin.", "Hal Finney"),

        // Wei Dai
        ("I am fascinated by Tim May's crypto-anarchy. Unlike the communities traditionally associated with the word 'anarchy', in a crypto-anarchy the government is not temporarily destroyed but permanently forbidden and permanently unnecessary.", "Wei Dai"),

        // Nick Szabo
        ("Trusted third parties are security holes.", "Nick Szabo"),
        ("A lot of people automatically dismiss e-currency as a lost cause because of all the companies that failed since the 1990s. I hope it's obvious it was only the centrally controlled nature of those systems that doomed them.", "Nick Szabo"),

        // Adam Back
        ("Bitcoin is a technological tour de force.", "Adam Back"),

        // Other notable quotes
        ("In a time of deceit, telling the truth is a revolutionary act.", "George Orwell"),
        ("Those who would give up essential Liberty, to purchase a little temporary Safety, deserve neither Liberty nor Safety.", "Benjamin Franklin"),
        ("The only way to deal with an unfree world is to become so absolutely free that your very existence is an act of rebellion.", "Albert Camus"),
        ("Knowledge will forever govern ignorance; and a people who mean to be their own governors must arm themselves with the power which knowledge gives.", "James Madison"),
        ("Privacy is not for the passive.", "Jeffrey Rosen"),
    ]

    /// Returns a random privacy quote
    static func randomQuote() -> (quote: String, author: String) {
        quotes.randomElement() ?? quotes[0]
    }
}
