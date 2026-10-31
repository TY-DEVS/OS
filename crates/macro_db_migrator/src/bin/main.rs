use std::env;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let database_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://user:password@postgres:5432/macrodb".to_string());
    println!("[macro_db_migrator] Connecting to database at {database_url}...");

    // Retry connection up to 30 times (for postgres startup)
    let mut retries = 30;
    let pool = loop {
        match sqlx::PgPool::connect(&database_url).await {
            Ok(pool) => break pool,
            Err(e) => {
                retries -= 1;
                if retries == 0 {
                    eprintln!("[macro_db_migrator] Failed to connect to database: {e}");
                    return Err(Box::new(e));
                }
                println!("[macro_db_migrator] Database not ready yet ({e}), retrying in 2s ({retries} left)...");
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }
    };

    println!("[macro_db_migrator] Running macro_db migrations...");
    macro_db_migrator::MACRO_DB_MIGRATIONS.run(&pool).await?;
    println!("[macro_db_migrator] All database migrations applied successfully!");
    pool.close().await;
    Ok(())
}
