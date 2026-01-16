using FluentValidation;
using FluentValidation.AspNetCore;
using LibrarySystem.Api.Common;
using LibrarySystem.Api.Data;
using LibrarySystem.Api.Services;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.

builder.Services.AddControllers();
builder.Services.AddRouting(options => options.LowercaseUrls = true);
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    var xmlFile = $"{System.Reflection.Assembly.GetExecutingAssembly().GetName().Name}.xml";
    var xmlPath = Path.Combine(AppContext.BaseDirectory, xmlFile);
    options.IncludeXmlComments(xmlPath);
});

builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseSqlServer(builder.Configuration.GetConnectionString("DefaultConnection")));

builder.Services.AddScoped<IBookService, BookService>();
builder.Services.AddScoped<IMemberService, MemberService>();
builder.Services.AddScoped<ILoanService, LoanService>();

builder.Services.AddValidatorsFromAssemblyContaining<Program>();
builder.Services.AddFluentValidationAutoValidation();

builder.Services.AddExceptionHandler<GlobalExceptionHandler>();
builder.Services.AddProblemDetails();

// Named rather than a default policy, so that UseCors below states which policy it applies.
const string SpaCorsPolicy = "SpaCors";

// The SPA is deployed to a different App Service than the API, so the browser makes a real
// cross-origin request. Locally the Vite dev server proxies /api instead, so this list is
// empty in development - and an empty list correctly trusts no cross-origin caller at all,
// rather than falling back to trusting every one.
var allowedOrigins = builder.Configuration
    .GetSection("Cors:AllowedOrigins")
    .Get<string[]>() ?? [];

builder.Services.AddCors(options =>
{
    options.AddPolicy(SpaCorsPolicy, policy =>
    {
        if (allowedOrigins.Length == 0)
        {
            return;
        }

        policy.WithOrigins(allowedOrigins)
            .AllowAnyHeader()
            .AllowAnyMethod();
    });
});

// The deployment supplies this from the monitoring module's output; locally and under test it is
// absent. The guard is required, not defensive tidiness: this package now resolves to the
// OpenTelemetry-based Azure Monitor exporter, which throws "A connection string was not found"
// while the service provider is being built. Registering it unconditionally takes down every
// test that starts the application, with a failure that names telemetry nowhere in its message.
var applicationInsightsConnectionString = builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"];
if (!string.IsNullOrWhiteSpace(applicationInsightsConnectionString))
{
    builder.Services.AddApplicationInsightsTelemetry();
}

// AddDbContextCheck opens a connection through AppDbContext, so /health reports unhealthy
// when the database is unreachable instead of only when the process is dead. App Service's
// own health check and the pipeline's smoke test both read this endpoint.
builder.Services.AddHealthChecks()
    .AddDbContextCheck<AppDbContext>();

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    DatabaseStartup.Initialize(
        db,
        app.Configuration.GetValue("Database:MigrateOnStartup", true));
}

app.UseExceptionHandler();

// Configure the HTTP request pipeline.
// Gated on configuration rather than on the environment: the deployed API is a portfolio
// artefact that is meant to be browsable, and IsDevelopment() would have hidden it in Azure.
if (app.Configuration.GetValue<bool>("Swagger:Enabled"))
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();

// Ahead of UseAuthorization: a preflight request carries no credentials for authorization to
// act on, and a response that authorization rejects still needs its CORS headers to be
// readable by the browser.
app.UseCors(SpaCorsPolicy);

app.UseAuthorization();

app.MapControllers();
app.MapHealthChecks("/health");

app.Run();

public partial class Program
{
}
