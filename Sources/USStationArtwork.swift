import Foundation

enum USStationArtwork {
    // Use station IDs rather than brand names or frequencies, which can be shared.
    static func url(for stationID: String) -> URL? {
        verifiedURLs[stationID.lowercased()].flatMap(URL.init(string:))
    }

    private static let verifiedURLs = [
        // 181.FM - Kickin' Country
        "960d4bdc-0601-11e8-ae97-52543be04c81": "https://www.181.fm/images/og181fmlogo.jpg",
        // 70s 80s Disco Funk ModernSoul Boogie
        "bafbd6cc-65e0-4af7-907b-dd1c425e8917": "https://funky.radio/wp-content/uploads/2021/04/discofunk_logo_1200.png",
        // __80 HITS
        "9d5a5d73-f563-4f60-934d-dc9452e2ea0a": "https://assets.laut.fm/51443b263d4b82dd4e7c24b811b8ddd7?t=_640x640",
        // Ambient Sleeping Pill
        "961fa288-0601-11e8-ae97-52543be04c81": "https://ambientsleepingpill.com/icon/192.png",
        // ambient.fm
        "44b7f191-9478-46b0-a3b5-5a0ea2b2d64e": "https://ambient.fm/images/ambientfm_favicon_192x192.jpg",
        // BlogHaus Radio
        "e09849af-559a-4957-806f-067f93a2ab66": "https://cdn-profiles.tunein.com/s341040/images/logoq.jpg?t=638777754890000000",
        // Bloodlit Radio
        "6dd54f08-b850-4a6f-8296-77b82e7d3c09": "https://static.wixstatic.com/media/300571_563731532f02438c9c01183ea0f965d9~mv2.jpeg/v1/fill/w_1188,h_416,al_c,q_85,enc_auto/BLOOOD%204.jpeg",
        // Chilltrax
        "9614537a-0601-11e8-ae97-52543be04c81": "https://www.chilltrax.com/images/apple-icon-180x180.png",
        // Conyers Old Time Radio
        "38055669-97a7-11e9-a605-52543be04c81": "https://player.yesstreaming.com/uploads/logos/1657394553_2a60c766d829113ee8f7.png",
        // CRIMETIME
        "2cc13176-02fb-4dc1-a5cd-5a9796faa36a": "https://cdn-radiotime-logos.tunein.com/s159842g.png",
        // East Tenneessee’s FM
        "cff15c5d-86f0-4c0b-8f0e-897ef382a97c": "https://wdvx.com/site/wp-content/uploads/2016/01/website-300x169.jpg",
        // EROTICA LOUNGE
        "74eac2e4-dd81-48d3-b47f-87f2f2a8b45a": "https://cdn-profiles.tunein.com/s260655/images/logog.png?t=159916",
        // FUNKY RADIO - Only Funk Music (60's & 70's)
        "439fafd7-b35b-4a6c-b22f-d9e4fbd9dfd4": "https://funky.radio/wp-content/uploads/2023/09/funky.radio_logo_512_90.webp",
        // Hard Rock Heaven
        "96336b01-0601-11e8-ae97-52543be04c81": "https://www.hrhradio.com/wp-content/uploads/2023/05/logo_cuadrado_fondo_negro-300x300.png",
        // Hard Rock Radio FM
        "9afeaf65-bb57-4d76-892d-c7a39fc6c805": "https://hardrockradiofm.weebly.com/uploads/6/0/1/4/60142111/hard-rock-radio-fm_orig.png",
        // iHeart Radio Café
        "52e142ff-1137-422a-b97e-75e27880abff": "https://i.iheart.com/v3/re/new_assets/6951",
        // LOVE RADIO Only Love Songs 70s80s90s - www.love.radio
        "7ab5fcfc-46ed-40be-9c47-27da8f8ef56c": "https://love.radio/wp-content/uploads/2023/11/LOVE.RADIO-only-love-songs_logo.webp",
        // Oroville Community Radio
        "0705ff0e-95f0-4f1b-b617-28684c2662a1": "https://krov.fm/theme/5/images/logo1.png",
        // Radiostorm - Comedy 104
        "a030301c-2fcc-4621-94f6-e09002c47fc1": "https://radiostorm.com/wp-content/uploads/2018/01/cropped-imgpsh_fullsize2-180x180.png",
        // The Jazz Groove (East)
        "8fd85d7d-5520-4b15-a7a2-cd8e713fb8f3": "https://cdn-profiles.tunein.com/s138946/images/logod.png?t=637707999350000000",
        // The Jazz Groove Mix 2
        "e41865c3-1c83-4ba4-89e2-4b6bf61ea02f": "https://assets.jazzgroove.org/logo-circle-white1-no-org.png",
        // TRAP RADIO TRAP.radio
        "63c56fba-2e27-4983-a78e-5798aba8d73a": "https://trap.radio/wp-content/uploads/2021/07/cropped-trapradio_international_logo512.png",
        // WCBN 88.3 Ann Arbor, MI
        "960ad5ce-0601-11e8-ae97-52543be04c81": "https://wcbn.org/wp-content/uploads/2022/08/cropped-wcbncolorlogo-1-1-192x192.png",
        // WDCB Jazz
        "6c1ddf4d-c407-4837-aa6c-73a99b5d598e": "http://wdcb.org/img/favicons/apple-touch-icon-120x120.png",
        // WOCM
        "478c9e31-197e-43fa-ac97-e9f6a6a012c7": "https://ocean98.com/media/images/mobile/icon/irie-512x512.png",
        // Your Classical - Peaceful Piano
        "f4562879-908f-4dc8-8908-d6c78b238e69": "https://img.apmcdn.org/1c913ad25eb3d0eebfda08e6ee2f3f4034346dad/square/a79a44-20210225-peaceful-piano-webp400.webp",
        // 星岛中文电台国语广播
        "00a9bccb-0ef6-42ea-94c2-25b0614a7f42": "http://www.chineseradio.com/main/wp-content/uploads/2026/10/cropped-favicon-gemini-300x300.jpg",
    ]
}
