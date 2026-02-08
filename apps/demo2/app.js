const express = require('express');
const path = require('path');
const app = express();
const PORT = 28882;

app.use(express.json());

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

app.get('/api/results', (req, res) => {
    res.json({
        app: 'Demo 2 - Survival Analysis',
        version: '1.0.0',
        results: [
            { patient: 'Patient 001', survival: 365, status: 'Alive', treatment: 'Chemotherapy' },
            { patient: 'Patient 002', survival: 730, status: 'Alive', treatment: 'Immunotherapy' },
            { patient: 'Patient 003', survival: 180, status: 'Deceased', treatment: 'Targeted Therapy' },
            { patient: 'Patient 004', survival: 540, status: 'Alive', treatment: 'Immunotherapy' },
            { patient: 'Patient 005', survival: 270, status: 'Deceased', treatment: 'Chemotherapy' }
        ]
    });
});

app.listen(PORT, () => {
    console.log(`Demo 2 server running on port ${PORT}`);
});
