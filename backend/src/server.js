import express from "express";
import pool from "./db.js";

const app = express();

app.use(express.json());

app.get("/health",(req, res) => {
    res.json({status:"ok"});
});

app.listen(process.env.PORT, () => {
    console.log("Servidor rodando");
});

app.get("/health/db",async (req, res) => {
    const resultado = await pool.query("SELECT NOW()");
    res.json(resultado.rows[0]);
});

