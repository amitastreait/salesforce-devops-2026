require('dotenv').config();
const { CometD } = require('cometd');
const jsforce = require('jsforce');
const fs = require('fs');
const axios = require('axios');
const jwt = require('jsonwebtoken');

async function jwtLogin(loginUrl, clientId, username) {
    const privateKey = fs.readFileSync(process.env.PRIVATE_KEY);

    const assertion = jwt.sign(
        {
            iss: clientId,
            sub: username,
            aud: loginUrl,
            exp: Math.floor(Date.now() / 1000) + 300
        },
        privateKey,
        { algorithm: 'RS256' }
    );

    const res = await axios.post(
        loginUrl + '/services/oauth2/token',
        new URLSearchParams({
            grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            assertion
        })
    );

    return res.data;
}

async function start() {
    try {
        /* =========================
           AUTH SOURCE ORG
        ========================= */
        const sourceAuth = await jwtLogin(
            process.env.SOURCE_LOGIN_URL,
            process.env.SOURCE_CLIENT_ID,
            process.env.SOURCE_USERNAME
        );

        console.log('✅ Source JWT Auth success');

        /* =========================
           AUTH TARGET ORG
        ========================= */
        const targetAuth = await jwtLogin(
            process.env.TARGET_LOGIN_URL,
            process.env.TARGET_CLIENT_ID,
            process.env.TARGET_USERNAME
        );

        console.log('✅ Target JWT Auth success');

        /* =========================
           COMETD SUBSCRIBER
        ========================= */
        const cometd = new CometD();

        cometd.configure({
            url: sourceAuth.instance_url + '/cometd/v65.0',
            requestHeaders: {
                Authorization: 'OAuth ' + sourceAuth.access_token
            },
            appendMessageTypeToURL: false
        });

        cometd.websocketEnabled = false;

        cometd.handshake(() => {
            console.log('🤝 Handshake success');

            cometd.subscribe(process.env.EVENT_CHANNEL, async (message) => {
                const payload = message.data.payload;

                console.log('🔥 Event received', payload);

                /* =========================
                   TARGET ORG OPERATION
                ========================= */
                await axios.post(
                    targetAuth.instance_url +
                        '/services/data/v65.0/sobjects/Integration_Log__c',
                    {
                        Event_Data__c: JSON.stringify(payload)
                    },
                    {
                        headers: {
                            Authorization: 'Bearer ' + targetAuth.access_token,
                            'Content-Type': 'application/json'
                        }
                    }
                );

                console.log('🚀 Data pushed to Target Org');
            });
        });

    } catch (e) {
        console.error('❌ Error', e.response?.data || e.message);
    }
}

start();