const express = require('express');
const cors = require('cors');
const app = express();
const PORT = 28881;

app.use(cors());
app.use(express.json());

app.get('/genes', (req, res) => {
    res.json({
        success: true,
        data: [
            { id: 1, gene: 'TP53', expression: 12.5, sample: 'Sample A', chromosome: '17p13.1' },
            { id: 2, gene: 'BRCA1', expression: 8.3, sample: 'Sample A', chromosome: '17q21' },
            { id: 3, gene: 'EGFR', expression: 15.2, sample: 'Sample A', chromosome: '7p11.2' },
            { id: 4, gene: 'KRAS', expression: 9.7, sample: 'Sample A', chromosome: '12p12.1' },
            { id: 5, gene: 'PTEN', expression: 6.4, sample: 'Sample A', chromosome: '10q23.31' }
        ]
    });
});

app.get('/genes/:id', (req, res) => {
    const geneId = parseInt(req.params.id);
    const genes = [
        { id: 1, gene: 'TP53', expression: 12.5, sample: 'Sample A', chromosome: '17p13.1', function: 'Tumor suppressor' },
        { id: 2, gene: 'BRCA1', expression: 8.3, sample: 'Sample A', chromosome: '17q21', function: 'DNA repair' },
        { id: 3, gene: 'EGFR', expression: 15.2, sample: 'Sample A', chromosome: '7p11.2', function: 'Growth factor receptor' },
        { id: 4, gene: 'KRAS', expression: 9.7, sample: 'Sample A', chromosome: '12p12.1', function: 'Signal transduction' },
        { id: 5, gene: 'PTEN', expression: 6.4, sample: 'Sample A', chromosome: '10q23.31', function: 'Phosphatase' }
    ];
    const gene = genes.find(g => g.id === geneId);
    if (gene) {
        res.json({ success: true, data: gene });
    } else {
        res.status(404).json({ success: false, error: 'Gene not found' });
    }
});

app.get('/health', (req, res) => {
    res.json({ success: true, status: 'healthy', service: 'demo1-backend' });
});

app.listen(PORT, () => {
    console.log(`Demo1 Backend API running on port ${PORT}`);
    console.log(`API endpoints:`);
    console.log(`  GET /health - Health check`);
    console.log(`  GET /genes - List all genes`);
    console.log(`  GET /genes/:id - Get gene by ID`);
});
