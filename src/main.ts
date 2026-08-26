import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import cookieParser from 'cookie-parser';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  // See docs/security-technical.md §CORS policy — credentials: true is
  // required for the refresh-token cookie (SameSite=None, cross-site by design
  // between GitHub Pages and Vercel).
  const allowedOrigin = process.env.CORS_ORIGIN;
  app.enableCors({
    origin: process.env.NODE_ENV === 'production' ? allowedOrigin : true,
    methods: ['GET', 'POST', 'PATCH', 'DELETE'],
    credentials: true,
  });

  app.use(cookieParser());

  // See docs/security-technical.md §Input validation.
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );

  await app.listen(process.env.PORT ?? 3000);
}
void bootstrap();
